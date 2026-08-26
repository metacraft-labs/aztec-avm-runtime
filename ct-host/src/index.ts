// The ct-host surface, in one place, so a consumer imports from here rather than reaching into a
// file. node-host's convention, for node-host's reason.
//
// Note what is NOT re-exported: there is no way to construct a `ResolvedTracingConfig` other than
// `resolveTracingConfig`, and no second constructor for `CtWriter`. The DD-7 gate is only a gate
// if every public route passes through it, and `test_dropped_column_awareness_asserted` enumerates
// this file's exports and tries each one.

export {
  ADDRESS_LEN,
  CT_ERR_ALREADY_OPEN,
  CT_ERR_BAD_LENGTH,
  CT_ERR_BAD_UTF8,
  CT_ERR_NO_SESSION,
  CT_ERR_NULL,
  CT_ERR_RESERVED_NOT_ZERO,
  CT_ERR_WRITER,
  CT_OK,
  OFF_ADDRESS,
  OFF_CONTEXT_ID,
  OFF_DA_GAS,
  OFF_L2_GAS,
  OFF_OPCODE,
  OFF_PC,
  OFF_RESERVED,
  RECORD_SIZE,
  REQUIRED_EXPORTS,
  WRITER_KIND_PATH_A_PURE_RUST,
  decodeStep,
  encodeStep,
  statusText,
  type CtWriterExports,
  type StepEvent,
} from './abi.ts';

export {
  CARRIES_COLUMNS,
  ColumnAwarenessDropped,
  ColumnAwarenessUnavailable,
  UnresolvedTracingConfig,
  WRITER_KIND_OF,
  WRITER_PATH_A_PURE_RUST,
  WRITER_PATH_B_NIM,
  isResolvedTracingConfig,
  resolveTracingConfig,
  type ResolvedTracingConfig,
  type TracingConfig,
  type WriterPath,
} from './config.ts';

export {
  CtWriter,
  CtWriterError,
  DEFAULT_BATCH_RECORDS,
  instantiateCtWriter,
  writerKindMatchesPath,
  type CtRecording,
  type CtWriterOptions,
} from './writer.ts';
