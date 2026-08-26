// resident_contracts_db.ts — the contracts DB `PublicProcessor` drives, over the contract store
// that lives inside `avm.wasm`.
//
// WHY AN ADAPTER AND NOT UPSTREAM'S CLASS. Upstream hands `PublicProcessor` a
// `PublicContractsDB`, whose store is a stack of TypeScript maps and whose miss path falls
// through to a `ContractDataSource`. It is vendored beside this file and it works — but in THIS
// runtime it would be the wrong store: the AVM reads contracts out of the module's own resident
// `ContractDBInterface` (REACTOR-ABI.md's eight methods), so a contract published in a block and
// recorded only in a TypeScript map would be invisible to the very interpreter that has to call
// it. Two stores holding different answers to the same question is the failure M13 spent a
// milestone on, one level down, with the two CHECKPOINT stacks.
//
// So this class forwards the writes and the checkpoints to the module, and REFUSES the reads.
//
// THE READS ARE REFUSED ON PURPOSE, and the reason is the same one. `PublicContractsDBInterface`
// declares four reads — instance, class, bytecode commitment, debug function name — and every one
// of them is already answered, inside the module, by the export of the same name, to the only
// caller that needs them. Answering them again here would mean decoding
// `ContractInstanceWithAddress` and `ContractClassPublic` back out of the module's msgpack and
// handing a SECOND view of the same data to a TypeScript caller. Nothing in this runtime asks;
// `PublicProcessor` never calls a read on its contracts DB, which is asserted rather than
// asserted-about. If something starts asking, a named throw at its call site is what this
// campaign wants over a plausible `undefined` — M21's `strictSurface` and
// `resident_merkle_operations.ts` both say why in more detail.
//
// REGISTRATION IS DEFERRED, AND THE REASON IS AN ASYNC HASH BEHIND A SYNCHRONOUS INTERFACE.
// `PublicContractsDBInterface.addNewContracts(tx)` is declared `void` and upstream calls it
// without awaiting, because upstream's implementation only puts objects in a map — the bytecode
// commitment is computed LATER, lazily, in the async `getBytecodeCommitment`. The module's
// `avm_contract_db_register_class` takes `publicBytecodeCommitment` as a field, and
// `computePublicBytecodeCommitment` is async (it is a poseidon hash over the packed bytecode).
// An adapter cannot await inside a synchronous method, and faking a commitment is not an option:
// the AVM checks it.
//
// So `addNewContracts` does the SYNCHRONOUS half — extract the deployment events, which is
// upstream's own `AllContractDeploymentData.fromTx` plus the two published event extractors — and
// queues them; `flush()` does the async half. `pendingRegistrations` is public so a caller, or a
// check, can see the queue is non-empty before the flush and empty after, rather than trusting
// that the flush did something.
//
// WHAT THAT COSTS, STATED RATHER THAN DISCOVERED LATER: a contract published by transaction N is
// callable from transaction N+1 only if a flush happens between them, and `PublicProcessor.process`
// has no seam to put one in. `assembleBlock` flushes once, after the block's transactions have
// run, so a contract published in block B is callable in block B+1 and NOT in the remainder of
// block B. That is the deliverable's own wording — "makes the contract callable in a LATER
// block" — and it is a limitation of the seam rather than of the module.

import { Fr } from '@aztec/foundation/curves/bn254';
import { ContractClassPublishedEvent } from '@aztec/protocol-contracts/class-registry';
import { ContractInstancePublishedEvent } from '@aztec/protocol-contracts/instance-registry';
import { serializeWithMessagePack } from '@aztec/stdlib/avm';
import type { AztecAddress } from '@aztec/stdlib/aztec-address';
import {
  AllContractDeploymentData,
  type ContractClassPublic,
  type ContractInstanceWithAddress,
  computePublicBytecodeCommitment,
} from '@aztec/stdlib/contract';
import type { Tx } from '@aztec/stdlib/tx';

import type { ResidentMerkleModule } from './resident_merkle_operations.ts';

/** Thrown by every read this adapter deliberately does not answer. */
export class ResidentContractsDbCannotAnswer extends Error {
  readonly kind = 'resident-contracts-db-cannot-answer' as const;
  readonly method: string;
  constructor(method: string) {
    super(
      `${method} is not answered by the resident contracts DB: the module answers it internally, `
        + `through avm_contract_db_${method.replace(/[A-Z]/g, c => '_' + c.toLowerCase())}, to the `
        + `only caller that needs it. A second TypeScript view of the same store could disagree `
        + `with the one the AVM reads.`,
    );
    this.name = 'ResidentContractsDbCannotAnswer';
    this.method = method;
  }
}

/** The reads that refuse, by name. Pinned so a check compares a set rather than a sentence. */
export const REFUSING_CONTRACT_READS: readonly string[] = Object.freeze([
  'getContractInstance',
  'getContractClass',
  'getBytecodeCommitment',
  'getDebugFunctionName',
]);

/** One queued registration: a class, an instance, or both, as one transaction produced them. */
export interface PendingRegistration {
  readonly classes: readonly ContractClassPublic[];
  readonly instances: readonly ContractInstanceWithAddress[];
}

/**
 * `ProcessorContractsDB` over the module's resident contract store.
 *
 * Satisfies the narrowed type the vendored `PublicProcessor` takes: the three checkpoint methods
 * and `addNewContracts`, plus the four reads it refuses.
 */
export class ResidentContractsDB {
  private readonly module: ResidentMerkleModule;
  private readonly handle: number;
  private readonly queue: PendingRegistration[] = [];
  /** Every class id and address already sent, so a repeated deployment is not double-registered. */
  private readonly sentClasses = new Set<string>();
  private readonly sentInstances = new Set<string>();
  private depth = 0;

  constructor(module: ResidentMerkleModule, handle: number) {
    this.module = module;
    this.handle = handle;
  }

  // -- the write half ---------------------------------------------------------------------------

  /**
   * The synchronous half: extract this transaction's deployments and queue them.
   *
   * The extraction is upstream's own, in three published calls — `AllContractDeploymentData.fromTx`
   * splits the transaction's logs into the non-revertible and revertible halves, and the two event
   * classes turn each half's logs into typed events. Doing that here rather than reading the logs
   * ourselves is what keeps the revertible/non-revertible split upstream's decision.
   */
  addNewContracts(tx: Tx): void {
    const all = AllContractDeploymentData.fromTx(tx);
    const classes: ContractClassPublic[] = [];
    const instances: ContractInstanceWithAddress[] = [];
    for (const half of [all.getNonRevertibleContractDeploymentData(), all.getRevertibleContractDeploymentData()]) {
      for (const event of ContractClassPublishedEvent.extractContractClassEvents(half.getContractClassLogs())) {
        classes.push(event.toContractClassPublic());
      }
      for (const event of ContractInstancePublishedEvent.extractContractInstanceEvents(half.getPrivateLogs())) {
        instances.push(event.toContractInstance());
      }
    }
    if (classes.length > 0 || instances.length > 0) {
      this.queue.push({ classes, instances });
    }
  }

  /** How many transactions' worth of deployments are queued and not yet in the module. */
  get pendingRegistrations(): number {
    return this.queue.length;
  }

  /**
   * The async half: drain the queue into the module.
   *
   * Returns how many classes and instances were actually SENT — not how many were queued — so a
   * caller can tell a flush that registered something from one that de-duplicated everything away.
   */
  async flush(): Promise<{ classes: number; instances: number }> {
    let classes = 0;
    let instances = 0;
    while (this.queue.length > 0) {
      const entry = this.queue.shift()!;
      for (const contractClass of entry.classes) {
        if (await this.registerClass(contractClass)) {
          classes += 1;
        }
      }
      for (const instance of entry.instances) {
        if (this.registerInstance(instance)) {
          instances += 1;
        }
      }
    }
    return { classes, instances };
  }

  /**
   * Register a contract class in the module. Returns false if it was already there.
   *
   * `publicBytecodeCommitment` is not a field of `ContractClassPublic`, so it is computed with
   * upstream's own `computePublicBytecodeCommitment` — the same function `PublicContractsDB`
   * calls, so no two stores in this process can hold different commitments for one bytecode.
   * The msgpack shape is `ContractClassWithCommitment`; it and the instance tuple below are
   * lifted from `diffsim/src/public/public_tx_simulator/differential/resident_avm.ts`, which is
   * where they were first measured against the module.
   */
  async registerClass(contractClass: ContractClassPublic): Promise<boolean> {
    const key = contractClass.id.toString();
    if (this.sentClasses.has(key)) {
      return false;
    }
    this.sentClasses.add(key);
    const publicBytecodeCommitment = await computePublicBytecodeCommitment(contractClass.packedBytecode);
    this.module.callWithBlob(
      'avm_contract_db_register_class',
      this.handle,
      serializeWithMessagePack({
        id: contractClass.id,
        artifactHash: contractClass.artifactHash,
        privateFunctionsRoot: contractClass.privateFunctionsRoot,
        packedBytecode: contractClass.packedBytecode,
        publicBytecodeCommitment,
      }),
    );
    return true;
  }

  /**
   * Register a contract instance under its address. Returns false if it was already there.
   *
   * SEVEN FIELDS AND ONLY SEVEN. `ContractInstanceWithAddress` additionally carries `version` and
   * `address`; `address` is the tuple's first element and `version` has no C++ counterpart at all,
   * so passing the object straight through would send a map with two keys the far side has no
   * field for. `publicKeys` IS passed through, because upstream's `PublicKeys` already spells its
   * six fields exactly as the C++ struct's msgpack does.
   */
  registerInstance(instance: ContractInstanceWithAddress): boolean {
    const key = instance.address.toString();
    if (this.sentInstances.has(key)) {
      return false;
    }
    this.sentInstances.add(key);
    this.module.callWithBlob(
      'avm_contract_db_register_instance',
      this.handle,
      serializeWithMessagePack([
        instance.address,
        {
          salt: instance.salt,
          deployer: instance.deployer,
          currentContractClassId: instance.currentContractClassId,
          originalContractClassId: instance.originalContractClassId,
          initializationHash: instance.initializationHash,
          immutablesHash: instance.immutablesHash,
          publicKeys: instance.publicKeys,
        },
      ]),
    );
    return true;
  }

  // -- checkpoints ------------------------------------------------------------------------------

  createCheckpoint(): void {
    this.module.callWithHandle('avm_contract_db_create_checkpoint', this.handle);
    this.depth += 1;
  }

  commitCheckpoint(): void {
    if (this.depth === 0) {
      throw new Error('resident contracts DB: no checkpoint to commit');
    }
    this.module.callWithHandle('avm_contract_db_commit_checkpoint', this.handle);
    this.depth -= 1;
  }

  revertCheckpoint(): void {
    if (this.depth === 0) {
      throw new Error('resident contracts DB: no checkpoint to revert');
    }
    this.module.callWithHandle('avm_contract_db_revert_checkpoint', this.handle);
    this.depth -= 1;
  }

  /** The depth this side is counting, so lockstep with the merkle DB is assertable. */
  get checkpointDepth(): number {
    return this.depth;
  }

  // -- the reads, refused -------------------------------------------------------------------------

  getContractInstance(_address: AztecAddress, _timestamp: bigint): Promise<never> {
    throw new ResidentContractsDbCannotAnswer('getContractInstance');
  }

  getContractClass(_contractClassId: Fr): Promise<never> {
    throw new ResidentContractsDbCannotAnswer('getContractClass');
  }

  getBytecodeCommitment(_contractClassId: Fr): Promise<never> {
    throw new ResidentContractsDbCannotAnswer('getBytecodeCommitment');
  }

  getDebugFunctionName(_address: AztecAddress, _selector: unknown): Promise<never> {
    throw new ResidentContractsDbCannotAnswer('getDebugFunctionName');
  }
}
