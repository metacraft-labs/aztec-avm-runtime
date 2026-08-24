// The node host: TypeScript bindings over `avm.wasm`'s ABI, on `node:wasi`.
//
// The whole surface, in one place, so a consumer (M18's orchestration, M24/M25's tracing) imports
// from here rather than reaching into a file.

export {
  AvmHostError,
  AvmInstancePoisoned,
  AvmTrap,
  isTrapLike,
  outcomeOf,
  unreachableKind,
  type AvmFailure,
  type AvmReactorError,
  type TxOutcome,
} from './errors.ts';

export {
  AvmEngineUnsupported,
  AvmToolchainRegression,
  AvmUnknownImport,
  LEGACY_EH_PROBE,
  TRY_TABLE_PROBE,
  assertExceptionSupport,
  compileAvm,
  engineAcceptsLegacyEh,
  engineAcceptsTryTable,
  instantiateAvm,
  memoryBytes,
  sectionIds,
  type CompiledAvm,
  type InstantiateOptions,
} from './loader.ts';

export { PAGE_BYTES, readMemoryImport, type MemoryImport } from './memory.ts';
export { Decoder, hexOf, unpack, type MsgpackValue } from './msgpack.ts';
export { AVM_STATUS_OK, Reactor, type ReactorExports } from './reactor.ts';
export { InstancePool, ModuleCache, type PoolStats } from './pool.ts';
export {
  drainSteps,
  expectedCrossings,
  formatStep,
  stepCount,
  stepsFromOutcome,
  type DrainResult,
  type ExecutionStep,
} from './steps.ts';
export {
  Transcript,
  blobFrom,
  dumpResult,
  parseInputs,
  programNames,
  runProgram,
  seedProgram,
  snapshots,
} from './transcript.ts';
