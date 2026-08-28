// The differential arm: ONE corpus program, run in a page, against the NATIVE x86-64 driver's own
// per-record transcript of the same program.
//
// ===========================================================================================
// THIS IS A NEGATIVE-CONTROL-SHAPED MEASUREMENT SURFACE, NOT A FEATURE. IT IS NOT IN
// `entry_browser.ts` AND THE PRODUCT'S MODULE GRAPH DOES NOT CONTAIN IT.
// ===========================================================================================
//
// `browser/demo/main.ts` already carries one function whose whole purpose is to be measured —
// `loadProvingStack`, the negative control for DD-11 — and records why: an absence measured by an
// instrument that has never seen the thing is worth nothing. This is the same shape for M29's
// second claim. `e2e_browser_container_opcodes_match_native` says that what a PAGE observes through
// M9's hook is what the C++ AVM observes on x86-64, and a claim about the browser has to be
// measured in a browser.
//
// ===========================================================================================
// WHY THE INPUTS COME FROM THE NATIVE DRIVER RATHER THAN BEING BUILT HERE.
// ===========================================================================================
//
// `avm_differential reactorinputs` (M12's mode) emits, per corpus program, the four msgpack blobs
// that seed the resident DBs — contract class, contract instance, deployment nullifier, fee-juice
// public-data leaf — and an `AvmFastSimulationInputs` with `collect_execution_steps = true`. They
// are UPSTREAM's own serialisations of upstream's own types, produced by the same binary that
// prints the native transcript this arm is compared against.
//
// That matters for the reason M12 recorded when it wrote the mode: a transaction assembled
// independently on each side would make the comparison a test of two assemblers. Here both sides
// are handed the same bytes, so what is left in the difference is the interpreter and the boundary.
//
// The exclusion list for that comparison is EMPTY, and that is a measurement rather than a
// convenience: `ExecutionStep` carries `(context_id, contract_address, pc, opcode, gas_used)` and
// every one of the five is compared. M26's review is the reason this sentence exists — an exclusion
// list is where a bug hides — so there is nothing to exclude and nothing to keep a test alive for.
//
// ===========================================================================================
// FRESH DB HANDLES, AND NOT THE RUNTIME'S.
// ===========================================================================================
//
// This creates and destroys its own `avm_contract_db_create` / `avm_merkle_db_create` handles
// rather than borrowing `OpenedRuntime`'s, so a parity run cannot leave a corpus contract or a
// nullifier in the trees the demo's own transaction executes against. It shares only the module
// instance, which is what makes it a measurement OF that instance.

import { drainSteps, stepCount, type ExecutionStep } from '../../node-host/src/steps.ts';
import type { Reactor } from '../../node-host/src/reactor.ts';
import { DEFAULT_STEP_BATCH, INSTRUCTIONS_EXECUTED_STAT, formatExecutedStep } from './executed_steps.ts';

/** The five blobs `avm_differential reactorinputs` prints for one program, already decoded. */
export interface ParityInputs {
  readonly program: string;
  readonly setupClass: Uint8Array;
  readonly setupInstance: Uint8Array;
  readonly setupNullifier: Uint8Array;
  readonly setupPublicData: Uint8Array;
  /** `AvmFastSimulationInputs` with `collect_execution_steps = true`. */
  readonly fastSteps: Uint8Array;
}

export interface ParityResult {
  readonly program: string;
  /** `avm_steps_count()` — the module's own count. */
  readonly count: number;
  /** Records decoded through `avm_steps_batch`. Equal to `count`; kept apart so a gap shows. */
  readonly decoded: number;
  readonly crossings: number;
  readonly batchRecords: number;
  /** Every record, in `avm_differential steps`' own shape, for a PER-RECORD comparison. */
  readonly records: readonly string[];
  readonly revertCode: number;
  readonly instructionsExecuted: number | null;
  /** `avm_abi_version()`, so a module/driver mismatch is a named number rather than a diff. */
  readonly abiVersion: number;
}

/** Hex without a `0x`, as the driver prints it, to bytes. Throws on an odd or non-hex string. */
export function hexToBytes(hex: string): Uint8Array {
  if (hex.length % 2 !== 0) throw new Error(`hex blob has an odd length: ${hex.length}`);
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    const byte = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    if (!Number.isInteger(byte)) throw new Error(`hex blob is not hex at offset ${i * 2}`);
    out[i] = byte;
  }
  return out;
}

/**
 * Seed a fresh pair of resident DBs, simulate the program, drain the stream.
 *
 * The handles are destroyed in a `finally`, so a simulation that throws does not leak them into a
 * page that goes on to run the demo's own transaction.
 */
export function runNativeParity(
  reactor: Reactor,
  inputs: ParityInputs,
  batchRecords: number = DEFAULT_STEP_BATCH,
): ParityResult {
  const abiVersion = reactor.abiVersion();
  const cdb = reactor.createContractDb();
  const mdb = reactor.createMerkleDb();
  try {
    reactor.callWithBlob('avm_contract_db_register_class', cdb, inputs.setupClass);
    reactor.callWithBlob('avm_contract_db_register_instance', cdb, inputs.setupInstance);
    reactor.callWithBlob('avm_merkle_db_insert_indexed_leaves_nullifier_tree', mdb, inputs.setupNullifier);
    reactor.callWithBlob('avm_merkle_db_insert_indexed_leaves_public_data_tree', mdb, inputs.setupPublicData);

    const outcome = reactor.simulate(inputs.fastSteps, cdb, mdb);
    const result = outcome.result as { stats?: Record<string, unknown> } | null;
    const raw = result?.stats?.[INSTRUCTIONS_EXECUTED_STAT];
    const instructionsExecuted =
      raw === undefined || raw === null ? null : Number(typeof raw === 'string' ? raw : (raw as number));

    const count = stepCount(reactor);
    const drained = drainSteps(reactor, batchRecords, count);
    return {
      program: inputs.program,
      count,
      decoded: drained.decoded,
      crossings: drained.crossings,
      batchRecords,
      records: drained.steps.map((s: ExecutionStep) => formatExecutedStep(s)),
      revertCode: outcome.revertCode,
      instructionsExecuted: Number.isFinite(instructionsExecuted as number) ? instructionsExecuted : null,
      abiVersion,
    };
  } finally {
    if (!reactor.poisoned) {
      reactor.destroyContractDb(cdb);
      reactor.destroyMerkleDb(mdb);
    }
  }
}
