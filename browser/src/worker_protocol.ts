// worker_protocol.ts — the message protocol between a page and its worker-hosted dev node.
//
// ===========================================================================================
// THE PROTOCOL IS UPSTREAM'S SHAPE, NOT A DESIGN OF OURS. WHAT IS OURS IS THE OPERATION LIST.
// ===========================================================================================
//
// `aztec-packages/yarn-project/end-to-end/src/test-wallet/` is a page-side client
// (`worker_wallet.ts`, 216 lines), a worker script (`wallet_worker_script.ts`, 66) and a protocol
// declaration (`worker_wallet_schema.ts`, 14) — upstream hosting a wallet in a worker, over exactly
// the four moving parts this file needs. Its protocol is an `ApiSchema`: a record of
// `z.function({ input: z.tuple([...]), output: ... })`, driven by four helpers out of
// `@aztec/foundation/schemas` —
//
//     schemaHasMethod(schema, fn)          the method exists and is a function schema
//     getSchemaParameters(schema[fn])      the input tuple, for parsing the arguments
//     parseWithOptionals(args, params)      …tolerating trailing optionals
//     getSchemaReturnType(schema[fn])      the output schema, for parsing the reply
//
// with `jsonStringify` on the way out and `JSON.parse` + the schema on the way in, on BOTH ends.
// That is the whole of upstream's worker-boundary discipline and it is reused here unchanged; the
// declaration below is the same kind of object as `WorkerWalletSchema`, over this runtime's own
// facade instead of over `Wallet`.
//
// SO A `Tx` CROSSING THE BOUNDARY IS ENCODED BY `Tx.schema`, a contract class by
// `ContractClassPublicSchema`, an address by `AztecAddress.schema` and a field by `schemas.Fr` —
// upstream's own codecs, the same ones its JSON-RPC servers use. Nothing here invents a wire format
// for somebody else's type, which is the parallel-type mistake `CHAIN-LOOP.md` §5 names one level
// up.
//
// ===========================================================================================
// WHAT IS *NOT* CARRIED BY THE SCHEMA CHANNEL, AND WHY EACH EXCEPTION IS NAMED
// ===========================================================================================
//
// Two operations cannot go through a JSON codec and are declared as exceptions rather than left to
// be discovered:
//
//   `takeContainer`  a `.ct` container is MEGABYTES. `jsonStringify` of a `Uint8Array` is the copy
//                    this milestone exists to avoid, so the container crosses as a TRANSFERABLE and
//                    its metadata — which is small, and is JSON — crosses through `recordContainer`
//                    on the schema channel beside it.
//   `subscribe`      a callback is not a value. It crosses as a `Comlink.proxy`, and the EVENTS it
//                    delivers are `jsonStringify`d by the worker and parsed by the client against
//                    the schemas below, so the payloads stay on upstream's codecs even though the
//                    delivery does not.
//
// `WORKER_OFF_SCHEMA_OPS` names both, and `verify` requires the union of the schema channel and
// this list to be the whole exposed surface — so a third exception cannot be added silently.
//
// ===========================================================================================
// DD-5: THE WORKER ADDS NO CAPABILITY THE BROWSER REFERENCE LACKS, AND THE RULE IS MECHANICAL
// ===========================================================================================
//
// M27 settled the shape of this argument for the Node entry point: `NODE_CONVENIENCES` is a VALUE
// in the built bundle, and the check requires `(node exports) − (browser exports)` to equal it as a
// SET, in both directions, so an undeclared addition fails and a declaration for something absent
// fails too. The same rule, one level along: every operation below declares the symbol that BACKS
// it, and every backing symbol must be an export of the built REFERENCE bundle (`browser.js`) —
// except the operations named in `WORKER_TESTING_OPS`, whose backings must be exports of
// `testing.js`. A worker operation that reached something neither entry point exports would be a
// capability the browser reference lacks, and it would fail rather than be argued about.

import { z } from 'zod';

import { schemas } from '@aztec/foundation/schemas';
import type { ApiSchema } from '@aztec/foundation/schemas';
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { Tx } from '@aztec/stdlib/tx';
import { ContractClassPublicSchema, ContractInstanceWithAddressSchema } from '@aztec/stdlib/contract';

// ---------------------------------------------------------------------------------------------
// The value shapes. Bigints travel as strings, which is `schemas.BigInt`'s own accepted input, and
// is what `ChainSnapshot` already does on disk (`avm_runtime.ts`: `timestamp: string`).
// ---------------------------------------------------------------------------------------------

/** Upstream's `AppendOnlyTreeSnapshot`, as the two numbers it is. */
export const ArchiveSchema = z.object({
  root: z.string(),
  nextAvailableLeafIndex: schemas.Integer,
});

/** One produced block, as much of it as crosses. `ChainBlock` itself carries `Tx` objects. */
export const BlockSummarySchema = z.object({
  number: schemas.Integer,
  timestamp: schemas.BigInt,
  wallClockSeconds: schemas.BigInt,
  wallClockDeviationSeconds: schemas.BigInt,
  empty: z.boolean(),
  txHashes: z.array(z.string()),
  failedTxHashes: z.array(z.string()),
  l1ToL2Messages: z.array(z.string()),
  archiveAfter: ArchiveSchema,
  /**
   * The worker's OWN `performance.now()` when this block was sealed.
   *
   * It is here because `smoke_worker_chain_survives_main_thread_block` has to say WHEN a block was
   * produced relative to a window the page defined, and the page cannot time it: the page is
   * blocked, which is the point. The worker times its own blocks on the same clock it timestamps
   * `NodeState.atMs` with, and the check reads the two together.
   */
  producedAtMs: z.number(),
});

/** What the facade's state queries answer, in one object so one round trip answers them all. */
export const NodeStateSchema = z.object({
  opened: z.boolean(),
  blockNumber: schemas.Integer,
  nextBlockNumber: schemas.Integer,
  lastBlockTimestamp: schemas.BigInt,
  nextBlockTimestamp: schemas.BigInt,
  blocks: schemas.Integer,
  archive: ArchiveSchema,
  /**
   * `StateReference.toBuffer()` as hex — upstream's own serialisation of the four-tree reference,
   * and the exact encoding `chain_e2e_driver.ts:486` uses for the snapshot round-trip M23 already
   * asserts on. Decomposing it into four roots here would be a second spelling of a state a
   * `toBuffer` already spells.
   */
  stateReferenceHex: z.string(),
  running: z.boolean(),
  ticks: schemas.Integer,
  /**
   * The worker's OWN `performance.now()` when it answered.
   *
   * WHICH MAKES `state()` THE MARKER `smoke_worker_chain_survives_main_thread_block` NEEDS, and
   * that is why it is on the state object rather than in an operation of its own. The page cannot
   * time the window — the page is blocked, which is the point — so it posts `state()` without
   * awaiting it, blocks, posts `state()` again, and then awaits both. Each reply carries the moment
   * the WORKER processed it, on the same clock as `BlockSummary.producedAtMs`, so "blocks produced
   * while the main thread was blocked" is a comparison between two readings of one clock and not
   * an inference across two.
   */
  atMs: z.number(),
  /** §8.4, carried across the boundary rather than re-derived on the page. */
  disclosure: z.object({
    simulated: z.literal(true),
    protocolVersion: z.string(),
    proving: z.literal('none'),
    line: z.string(),
  }),
});

export const TxReceiptSchema = z.object({
  txHash: z.string(),
  outcome: z.object({
    kind: z.enum(['queued', 'processed', 'failed', 'unprocessed']),
    blockNumber: schemas.Integer.optional(),
    error: z.string().optional(),
  }),
  blockNumber: schemas.Integer.nullable(),
  simulated: z.literal(true),
  protocolVersion: z.string(),
  proving: z.literal('none'),
});

/** M23's replay-log snapshot, exactly as `ChainSnapshot` declares it. */
export const ChainSnapshotSchema = z.object({
  format: z.literal('avm-runtime-replay-log'),
  version: z.literal(1),
  protocolVersion: z.string(),
  config: z.object({
    intervalMs: schemas.Integer,
    produceEmptyBlocks: z.boolean(),
    automine: z.boolean(),
    maxTxsPerBlock: schemas.Integer,
    minBlockSpacingSeconds: schemas.Integer,
  }),
  blocks: z.array(
    z.object({
      number: schemas.Integer,
      timestamp: z.string(),
      empty: z.boolean(),
      txs: z.array(z.string()),
      l1ToL2Messages: z.array(z.string()),
      archiveAfter: ArchiveSchema,
    }),
  ),
  funding: z.array(z.object({ feePayer: z.string(), amount: z.string() })),
});

/** What `open` needs. `moduleUrl` is resolved by the WORKER, which is what makes it lazy there. */
export const OpenRequestSchema = z.object({
  moduleUrl: z.string(),
  intervalMs: schemas.Integer.optional(),
  minBlockSpacingSeconds: schemas.Integer.optional(),
  produceEmptyBlocks: z.boolean().optional(),
  automine: z.boolean().optional(),
  collectExecutionSteps: z.boolean().optional(),
});

export const RecordRequestSchema = z.object({
  writerUrl: z.string(),
  artifactUrl: z.string(),
  recordingId: z.string(),
});

/** Everything about a recording except its bytes. The bytes are the transferable. */
export const ContainerMetaSchema = z.object({
  bytes: schemas.Integer,
  events: schemas.Integer,
  callsOpened: schemas.Integer,
  pathsInterned: schemas.Integer,
  stepsPositioned: schemas.Integer,
  stepsUnpositioned: schemas.Integer,
  writerKind: schemas.Integer,
  recordingId: z.string(),
  rung: schemas.Integer,
  declaredRung: schemas.Integer,
  stepProducer: z.string(),
  executedSteps: schemas.Integer,
  instructionsExecuted: schemas.Integer.nullable(),
  distinctOpcodes: schemas.Integer,
  contexts: schemas.Integer,
  filename: z.string(),
});

/**
 * What the worker can still see of the container's buffer.
 *
 * THIS IS THE MEASUREMENT `test_worker_transferable_container_not_copied` IS ABOUT, and it is taken
 * on the SOURCE side after the message has gone. A transfer detaches the sender's `ArrayBuffer`:
 * `byteLength` becomes 0 and `ArrayBuffer.prototype.detached` becomes true. A structured clone does
 * neither. So the two paths are distinguishable by a reading the worker takes of its own memory,
 * rather than by the page believing what the call site asked for.
 */
export const BufferStateSchema = z.object({
  present: z.boolean(),
  byteLength: schemas.Integer,
  detached: z.boolean(),
  /** How many times `takeContainer` has been called, and how many of those transferred. */
  takes: schemas.Integer,
  transfers: schemas.Integer,
  /**
   * A ZERO-LENGTH BUFFER THAT WAS NEVER TRANSFERRED, read by the same code in the same call.
   *
   * It is here because without it the claim beside `detached` is not exercised. The check says
   * `detached` is "the platform's own answer rather than an inference from a zero length" — but the
   * only zero-length buffer in the sequence IS the transferred one, so an implementation that
   * computed `detached = byteLength === 0` would agree with the platform at every point the check
   * looks and the sentence would be true of nothing. This control is `{byteLength: 0,
   * detached: false}`, which is the one combination an inference cannot produce.
   */
  zeroLengthControl: z.object({ byteLength: schemas.Integer, detached: z.boolean() }),
});

export const TokenTransferReportSchema = z.object({
  artifactName: z.string(),
  contractAddress: z.string(),
  outcome: z.string(),
  blockNumber: schemas.Integer.nullable(),
  revertCode: schemas.Integer.nullable(),
  debugFunctionNames: z.array(z.string().optional()),
  executedSteps: schemas.Integer.nullable(),
  instructionsExecuted: schemas.Integer.nullable(),
});

// ---------------------------------------------------------------------------------------------
// THE PROTOCOL.
// ---------------------------------------------------------------------------------------------

/**
 * The schema channel: every operation the page can ask of its worker-hosted node.
 *
 * The same kind of object as upstream's `WorkerWalletSchema`, and driven by the same helpers.
 */
export const AvmWorkerNodeSchema: ApiSchema = {
  // -- lifecycle ----------------------------------------------------------------------------
  open: z.function({ input: z.tuple([OpenRequestSchema]), output: NodeStateSchema }),
  close: z.function({ input: z.tuple([]), output: z.void() }),
  start: z.function({ input: z.tuple([]), output: z.void() }),
  stop: z.function({ input: z.tuple([]), output: z.void() }),

  // -- both submission forms ------------------------------------------------------------------
  submitExternal: z.function({ input: z.tuple([Tx.schema]), output: TxReceiptSchema }),
  submitLocal: z.function({ input: z.tuple([Tx.schema]), output: TxReceiptSchema }),

  // -- world ----------------------------------------------------------------------------------
  registerContract: z.function({
    input: z.tuple([ContractClassPublicSchema.nullable(), ContractInstanceWithAddressSchema.nullable()]),
    output: z.object({ classes: schemas.Integer, instances: schemas.Integer }),
  }),
  fundFeeJuice: z.function({ input: z.tuple([AztecAddress.schema, schemas.Fr]), output: schemas.Fr }),
  injectL1ToL2Message: z.function({ input: z.tuple([schemas.Fr]), output: z.void() }),

  // -- state queries --------------------------------------------------------------------------
  state: z.function({ input: z.tuple([]), output: NodeStateSchema }),
  blocks: z.function({ input: z.tuple([]), output: z.array(BlockSummarySchema) }),
  receiptFor: z.function({ input: z.tuple([z.string()]), output: TxReceiptSchema }),
  produceBlock: z.function({ input: z.tuple([]), output: BlockSummarySchema.nullable() }),
  advanceBlocksBy: z.function({ input: z.tuple([schemas.Integer]), output: z.array(BlockSummarySchema) }),

  // -- snapshot -------------------------------------------------------------------------------
  exportSnapshot: z.function({ input: z.tuple([]), output: ChainSnapshotSchema }),
  importSnapshot: z.function({ input: z.tuple([ChainSnapshotSchema]), output: NodeStateSchema }),

  // -- the `.ct` container: its METADATA. The bytes are `takeContainer`, off-schema by design. ---
  recordContainer: z.function({ input: z.tuple([RecordRequestSchema]), output: ContainerMetaSchema }),
  containerBufferState: z.function({ input: z.tuple([]), output: BufferStateSchema }),

  // -- testing (see WORKER_TESTING_OPS) --------------------------------------------------------
  runTokenTransfer: z.function({ input: z.tuple([z.string()]), output: TokenTransferReportSchema }),
};

/** Every operation on the schema channel, sorted. */
export const WORKER_PROTOCOL: readonly string[] = Object.freeze(Object.keys(AvmWorkerNodeSchema).sort());

/**
 * The two operations that are NOT on the schema channel, each with the reason it cannot be.
 *
 * Declared as data so the check can require `(exposed methods) − (schema channel) == this`, as a
 * set, in both directions.
 */
export const WORKER_OFF_SCHEMA_OPS: Readonly<Record<string, string>> = Object.freeze({
  takeContainer:
    'a `.ct` container is megabytes; a JSON codec would COPY it, which is the thing this milestone '
    + 'exists to avoid. It crosses as a transferable and its metadata crosses on the schema channel.',
  subscribe:
    'a callback is not a value. It crosses as a Comlink.proxy; the EVENTS it delivers are '
    + 'jsonStringify-ed by the worker and parsed against this file\'s schemas by the client.',
});

/** The three subscriptions `AvmRuntime.subscribe` offers. Named here so the check can enumerate. */
export const WORKER_SUBSCRIPTIONS: readonly string[] = Object.freeze(['block', 'tx', 'trace']);

/**
 * DD-5. Which exported symbol of the built bundles backs each operation.
 *
 * The values are EXPORT NAMES, read out of the BUILT artefacts by
 * `smoke_worker_chain_survives_main_thread_block` §5 — not out of this file. A name here that the
 * reference bundle does not export is a capability the browser reference lacks.
 */
export const WORKER_PROTOCOL_BACKING: Readonly<Record<string, string>> = Object.freeze({
  open: 'openAvmRuntime',
  close: 'openAvmRuntime',
  start: 'AvmRuntime',
  stop: 'AvmRuntime',
  submitExternal: 'AvmRuntime',
  submitLocal: 'AvmRuntime',
  registerContract: 'AvmRuntime',
  fundFeeJuice: 'AvmRuntime',
  injectL1ToL2Message: 'AvmRuntime',
  state: 'AvmRuntime',
  blocks: 'AvmRuntime',
  receiptFor: 'AvmRuntime',
  produceBlock: 'AvmRuntime',
  advanceBlocksBy: 'AvmRuntime',
  exportSnapshot: 'AvmRuntime',
  importSnapshot: 'AvmRuntime',
  recordContainer: 'recordAndDownload',
  containerBufferState: 'recordAndDownload',
  takeContainer: 'recordAndDownload',
  subscribe: 'AvmRuntime',
  runTokenTransfer: 'runTokenTransfer',
});

/**
 * The operations whose backing is exported by `testing.js` and NOT by `browser.js`.
 *
 * ONE, and it is M27's demo driver: `runTokenTransfer` composes M26's vendored transaction builder,
 * which is a test harness and lives in the testing entry point by DD-5's own rule.
 *
 * There is deliberately no `mark` operation beside it. An earlier draft had one — a marker the
 * worker timestamped so a check could bound a window — and it needed a backing symbol that does not
 * exist, which is a declaration written to satisfy a rule rather than to state a fact. `state()`
 * already crosses the boundary and already answers on the worker's clock; putting `atMs` on its
 * reply makes the marker a READING OF THE FACADE instead of an instrument beside it.
 */
export const WORKER_TESTING_OPS: readonly string[] = Object.freeze(['runTokenTransfer']);
