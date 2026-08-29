// settled_transaction.ts — L1: A TRANSACTION HASH BECOMES AN UPSTREAM `Tx` PLUS THE BLOCK
// COORDINATES NEEDED TO RE-EXECUTE IT.
//
// L0 built the client and the surface. This module is the one question that surface exists to ask,
// asked once, in one order, with every way of not being able to answer it named.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE DELIVERABLE THIS MODULE IS REALLY FOR.
//
// "Contract artifacts resolved through `getContract` / `getContractClass`, and a contract the node
// does not know is REFUSED BY NAME rather than executed against absent bytecode. The sibling
// campaign learned this the hard way: a transaction whose address had no bytecode produced one
// record, the sentinel opcode, and a well-formed container."
//
// That is not a footnote. It is the shape of every failure this campaign has actually shipped: a
// well-formed artefact over a subject that did not do anything, with every assertion around it
// correct. `MissingContractArtifact` is a THROW naming the address — never `undefined`, never an
// empty `contracts` array, never a `SettledTransaction` that a caller could carry on with.
//
// The refusal has THREE stages, because there are three different ways for the bytecode not to be
// there and a caller that gets "missing" deserves to know which:
//
//   `instance`  `getContract(address)` -> undefined. The contract was never published for public
//               execution, so the node has no instance and therefore no class id to ask about.
//   `class`     the instance is there and `getContractClass(currentContractClassId)` -> undefined.
//               The node knows where the contract is and not what it runs.
//   `bytecode`  both are there and `packedBytecode` is EMPTY. This is the sibling campaign's own
//               failure, exactly: an artefact that resolves, a length of zero, and an AVM that
//               starts, reads nothing, and emits a sentinel. A zero-length answer is not an answer.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// AND THE CONTROL IS A SECOND MODE OF THE SAME FUNCTION, NOT A SECOND FUNCTION.
//
// M32's review recorded a control that "was a SECOND EXPRESSION over a SECOND buffer, so it
// constrained its own code and not the container's". A control has to run through the instrument.
// So `resolvePublicContracts` takes `refuseUnknown`, and
// `resolvePublicContractsUnguardedForControls` is the same call with it `false` — one resolution
// path, one set of node calls, one flag. With the guard off, an unknown contract comes back as a
// resolution with `resolved: false` and `packedBytecodeBytes: 0` — which is precisely the
// well-formed nothing the guard exists to prevent, and a check can hold the two side by side.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// THE PUBLIC HALF IS DECLARED TOO, FOR THE SAME REASON THE PRIVATE ONE IS.
//
// A transaction with no enqueued public calls is a real and common thing on Aztec — the scan that
// found this milestone's fixtures met one in the same run. Its replay has nothing to execute, and
// an empty `contracts` array says that in exactly the same way it would say "the resolution
// failed". So `publicHalf` is a declaration with a count and a reason, and L2/L3 read the
// declaration rather than the array's length.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// A MEASURED FACT THIS MILESTONE FOUND AND NOTHING HAD RECORDED: `getTxByHash` HAS A HORIZON.
//
// Scanning recent testnet blocks on 2026-08-29: transactions near the tip answered `getTxByHash`,
// and older ones answered `undefined` while their `TxEffect` was still served in full —
// `getTxEffect` and the block body both had it. So the node retains EFFECTS indefinitely and
// TRANSACTION BODIES for a window.
//
// The consequence is L1's, not L2's: a replay needs the `Tx` (it is what `AvmTxHint.fromTx`
// consumes), so **a settled transaction can become unreplayable while remaining perfectly
// visible**. `SettledTransactionNotFound` is the right refusal for it and already says "a
// transaction that has not settled, or has been pruned, or never existed, all read this way" — but
// a caller staring at a block explorer showing the transaction needs the pruning case spelled out,
// which is why this paragraph is here and why the fixtures exist at all.
//
// THE WINDOW IS A FINALITY LAG, NOT A BLOCK COUNT — and the first draft of this paragraph said
// "the most recent ~36 blocks", which was two sightings four hours apart generalised into a
// constant. L1's review re-took it and got 54-65 blocks, then read the mechanism out of upstream
// at `anchors.cpp` instead of curve-fitting: `AztecNodeService.getTxByHash` serves only from the
// ACTIVE TX POOL (it never reaches the tx archive), and the pool deletes a mined transaction when
// its block is FINALIZED — `tx_pool_v2_impl.ts#prepareFinalization` uses the finalized block as
// its cutoff, with `keepFinalizedTxsForSlots` defaulting to 0.
//
// So the horizon is `getBlockNumber() - getBlockNumber('finalized')`: fixed in TIME (~52 minutes
// measured on testnet) and therefore variable in BLOCKS with the chain's production rate. DO NOT
// GUESS IT AND DO NOT HARD-CODE 36 — `getBlockNumber` is already on the permitted surface and
// takes a tag, so `getBlockNumber('finalized')` reads the horizon at run time and anything at or
// below it is already unfetchable. For a demo over "recent Aztec transactions" that is a
// refresh cadence of well under an hour, or a demo that silently degrades from debuggable to
// merely visible.

import type { AztecAddress } from '@aztec/stdlib/aztec-address';
import type { BlockData } from '@aztec/stdlib/block';
import type { ContractClassPublic, ContractInstanceWithAddress } from '@aztec/stdlib/contract';
import type { IndexedTxEffect, Tx } from '@aztec/stdlib/tx';
import type { TxHash } from '@aztec/stdlib/tx/tx-hash';

import type { ReplayNodeClient } from './node_client.ts';
import { declarePrivateHalf, type PrivateHalfDeclaration } from './private_half.ts';

// ---------------------------------------------------------------------------------------------
// The refusals
// ---------------------------------------------------------------------------------------------

/** Which of the three ways a contract can fail to resolve. See the module header. */
export const MISSING_ARTIFACT_STAGES = ['instance', 'class', 'bytecode'] as const;
export type MissingArtifactStage = (typeof MISSING_ARTIFACT_STAGES)[number];

/**
 * The node does not know a contract this transaction's public half calls.
 *
 * A THROW, naming the address — which is the milestone's own word, "refused by name". Returning a
 * resolution with no bytecode would let a caller build an `AvmTxHint`, hand it to the AVM, and get
 * back one record and a sentinel opcode inside a well-formed container: the sibling campaign's own
 * failure, which its review caught only because somebody re-read a transaction that had passed a
 * milestone, its review and a second milestone's floors.
 */
export class MissingContractArtifact extends Error {
  readonly kind = 'replay-missing-contract-artifact' as const;
  readonly address: string;
  readonly stage: MissingArtifactStage;
  /** The class id, when the failure is late enough for there to be one. */
  readonly contractClassId: string | undefined;
  readonly txHash: string;
  readonly url: string;

  constructor(args: {
    address: string;
    stage: MissingArtifactStage;
    contractClassId?: string | undefined;
    txHash: string;
    url: string;
  }) {
    super(
      `the Aztec node at ${args.url} does not know contract ${args.address}, which transaction `
        + `${args.txHash} calls in its public half: ${MissingContractArtifact.explain(args.stage)} `
        + (args.contractClassId ? `(contract class ${args.contractClassId}) ` : '')
        + `REFUSING rather than replaying: a replay that continued here would execute against `
        + `ABSENT BYTECODE and produce a well-formed container with one record and a sentinel `
        + `opcode in it, which reads as a transaction that did nothing rather than as a fetch that `
        + `failed. That artefact has already been shipped once in this campaign's history and this `
        + `refusal is the thing written to stop it happening again.`,
    );
    this.name = 'MissingContractArtifact';
    this.address = args.address;
    this.stage = args.stage;
    this.contractClassId = args.contractClassId;
    this.txHash = args.txHash;
    this.url = args.url;
  }

  static explain(stage: MissingArtifactStage): string {
    switch (stage) {
      case 'instance':
        return 'getContract returned nothing, so the contract was never published for public '
          + 'execution and there is no class id to ask about.';
      case 'class':
        return 'the instance is published but getContractClass returned nothing, so the node knows '
          + 'where the contract is and not what it runs.';
      case 'bytecode':
        return 'the class resolved and its packedBytecode is EMPTY, which is not an artefact — an '
          + 'AVM handed zero bytes starts, reads nothing and halts.';
    }
  }
}

/**
 * The transaction's own `TxEffect` names a settling block the node will not serve.
 *
 * Distinct from "the transaction is not found" on purpose: here the chain HAS the transaction and
 * has told us where it settled, and the block coordinates a replay needs — `GlobalVariables` for
 * the AVM, `StateReference` for L2's root check — are the thing that is missing. Collapsing this
 * into not-found would send a reader after the transaction hash.
 */
export class SettlingBlockUnavailable extends Error {
  readonly kind = 'replay-settling-block-unavailable' as const;
  readonly blockNumber: number;
  readonly txHash: string;
  readonly url: string;

  constructor(blockNumber: number, txHash: string, url: string) {
    super(
      `the Aztec node at ${url} says transaction ${txHash} settled in block ${blockNumber} and `
        + `then answered getBlockData(${blockNumber}) with nothing. The transaction IS on this `
        + `chain — this is not 'not found' — but the GlobalVariables the AVM needs and the `
        + `StateReference L2 compares hydrated roots against are both in that block, so there is `
        + `nothing to replay it against.`,
    );
    this.name = 'SettlingBlockUnavailable';
    this.blockNumber = blockNumber;
    this.txHash = txHash;
    this.url = url;
  }
}

// ---------------------------------------------------------------------------------------------
// Contract resolution
// ---------------------------------------------------------------------------------------------

/**
 * WHICH BLOCK A CONTRACT INSTANCE WAS RESOLVED AS OF. Today: `latest`, always — and that is a
 * STATED LIMITATION rather than an oversight, in M21's own shape.
 *
 * `getContract(address, referenceBlock?)` defaults to `'latest'`, and upstream's own doc comment
 * says the instance's *current class id* "is resolved as of the given reference block" — because a
 * contract whose class has been UPGRADED runs a different class now from the one it ran then. So a
 * replay of a transaction against an upgraded contract would fetch the bytecode the contract runs
 * TODAY and execute it as though it were the bytecode that ran in block N. Nothing would fail; the
 * answer would simply be about a different program.
 *
 * L1 does not pass the argument, so the value below is `latest` and a caller can see it. The fix is
 * one argument — the settling block — and it belongs to **L2**, whose whole deliverable is "the AVM
 * executing a settled transaction sees the state that transaction saw" and which has to pass a
 * reference block to the five membership-witness queries for the same reason. Declaring it here is
 * what stops it being discovered as a divergence somebody attributes to the runtime.
 */
export const CONTRACT_RESOLUTION_REFERENCE_BLOCK = 'latest' as const;

/** One contract the public half calls, and what the node had for it. */
export type ContractResolution = {
  readonly address: string;
  /** Always `latest` today. See `CONTRACT_RESOLUTION_REFERENCE_BLOCK`. */
  readonly resolvedAsOf: typeof CONTRACT_RESOLUTION_REFERENCE_BLOCK;
  readonly resolved: boolean;
  /** Absent when `resolved` is false, and `missing` says at which stage. */
  readonly missing: MissingArtifactStage | undefined;
  readonly contractClassId: string | undefined;
  readonly originalContractClassId: string | undefined;
  /** Zero when the bytecode is not there. NEVER a plausible non-zero for an absent artefact. */
  readonly packedBytecodeBytes: number;
  readonly instance: ContractInstanceWithAddress | undefined;
  readonly contractClass: ContractClassPublic | undefined;
};

/** The two node methods a resolution reaches, named so a check can assert they were the ones used. */
export const CONTRACT_RESOLUTION_METHODS = ['getContract', 'getContractClass'] as const;

/**
 * Resolve every contract a public half calls, through upstream's own two methods.
 *
 * `refuseUnknown` is the ONLY difference between the deliverable and its control. See the module
 * header for why the control is a mode of this function rather than a second function.
 */
export async function resolvePublicContracts(
  client: ReplayNodeClient,
  addresses: readonly AztecAddress[],
  options: { refuseUnknown: boolean; txHash: string },
): Promise<ContractResolution[]> {
  const out: ContractResolution[] = [];
  for (const address of addresses) {
    out.push(await resolveOne(client, address, options));
  }
  return out;
}

/**
 * The same resolution with the refusal off.
 *
 * EXPORTED FOR THE CONTROLS AND FOR NOTHING ELSE, and named so that is impossible to miss — L0's
 * `createUnguardedNodeClientForControls` is the precedent and the reason is the same: "the guard
 * refuses an unknown contract" is worth nothing unless something demonstrates what happens without
 * it, and what happens without it is a resolution object with `packedBytecodeBytes: 0` that looks
 * exactly like every other one.
 */
export function resolvePublicContractsUnguardedForControls(
  client: ReplayNodeClient,
  addresses: readonly AztecAddress[],
  txHash: string,
): Promise<ContractResolution[]> {
  return resolvePublicContracts(client, addresses, { refuseUnknown: false, txHash });
}

async function resolveOne(
  client: ReplayNodeClient,
  address: AztecAddress,
  options: { refuseUnknown: boolean; txHash: string },
): Promise<ContractResolution> {
  const addressText = address.toString();
  const refuse = (stage: MissingArtifactStage, contractClassId?: string): ContractResolution => {
    if (options.refuseUnknown) {
      throw new MissingContractArtifact({
        address: addressText,
        stage,
        contractClassId,
        txHash: options.txHash,
        url: client.url,
      });
    }
    return {
      address: addressText,
      resolvedAsOf: CONTRACT_RESOLUTION_REFERENCE_BLOCK,
      resolved: false,
      missing: stage,
      contractClassId,
      originalContractClassId: undefined,
      packedBytecodeBytes: 0,
      instance: undefined,
      contractClass: undefined,
    };
  };

  const instance = await client.getContract(address);
  if (instance === undefined || instance === null) {
    return refuse('instance');
  }
  const classId = instance.currentContractClassId.toString();
  const contractClass = await client.getContractClass(instance.currentContractClassId);
  if (contractClass === undefined || contractClass === null) {
    return refuse('class', classId);
  }
  const bytes = contractClass.packedBytecode?.length ?? 0;
  if (bytes === 0) {
    return refuse('bytecode', classId);
  }
  return {
    address: addressText,
    resolvedAsOf: CONTRACT_RESOLUTION_REFERENCE_BLOCK,
    resolved: true,
    missing: undefined,
    contractClassId: classId,
    originalContractClassId: instance.originalContractClassId.toString(),
    packedBytecodeBytes: bytes,
    instance,
    contractClass,
  };
}

// ---------------------------------------------------------------------------------------------
// The public half
// ---------------------------------------------------------------------------------------------

/** Declared rather than inferred from an array's length. See the module header. */
export type PublicHalfDeclaration = {
  readonly present: boolean;
  readonly enqueuedCalls: number;
  readonly hasTeardown: boolean;
  readonly reason: string;
};

/**
 * The addresses this transaction's public half will execute against, in call order, deduplicated.
 *
 * `getPublicCallRequestsWithCalldata()` is upstream's own accessor and it already returns the
 * non-revertible calls, then the revertible ones, then teardown — so the order is upstream's
 * execution order and not one this module invented. The teardown request is asked for separately
 * as well, because a transaction can have a teardown and no enqueued calls and the two accessors
 * disagreeing is exactly the kind of thing that would otherwise be discovered by an empty replay.
 */
export function publicCallTargets(tx: Tx): AztecAddress[] {
  const seen = new Set<string>();
  const out: AztecAddress[] = [];
  const push = (address: AztecAddress) => {
    const key = address.toString();
    if (!seen.has(key)) {
      seen.add(key);
      out.push(address);
    }
  };
  for (const request of tx.getPublicCallRequestsWithCalldata()) {
    push(request.request.contractAddress);
  }
  const teardown = tx.getTeardownPublicCallRequestWithCalldata();
  if (teardown !== undefined) {
    push(teardown.request.contractAddress);
  }
  return out;
}

export function declarePublicHalf(tx: Tx): PublicHalfDeclaration {
  const enqueuedCalls = tx.numberOfPublicCalls();
  const hasTeardown = tx.getTeardownPublicCallRequestWithCalldata() !== undefined;
  const present = enqueuedCalls > 0;
  return {
    present,
    enqueuedCalls,
    hasTeardown,
    reason: present
      ? `this transaction enqueued ${enqueuedCalls} public call(s)`
        + `${hasTeardown ? ', one of them a teardown' : ''}, so there is a public half to replay.`
      : 'this transaction enqueued NO public calls. Its whole execution was private, and the '
        + 'private half is unrecoverable in principle — so there is nothing here for an AVM to '
        + 'run. This is a declaration and not an empty contracts array, because an empty array is '
        + 'indistinguishable from a resolution that failed.',
  };
}

// ---------------------------------------------------------------------------------------------
// The fetch
// ---------------------------------------------------------------------------------------------

/** Everything L2 needs to re-execute a settled transaction, and everything L3 needs to say what it is. */
export type SettledTransaction = {
  readonly txHash: string;
  readonly tx: Tx;
  readonly txEffect: IndexedTxEffect;
  /** The block it settled in, from the effect and not from a guess. */
  readonly l2BlockNumber: number;
  readonly l2BlockHash: string;
  readonly txIndexInBlock: number;
  /** `header.globalVariables` for the AVM, `header.state` for L2's root check. */
  readonly blockData: BlockData;
  /** What the chain published about this transaction's outcome. L2's yardstick. */
  readonly revertCode: number;
  readonly publicHalf: PublicHalfDeclaration;
  readonly privateHalf: PrivateHalfDeclaration;
  readonly contracts: readonly ContractResolution[];
  /** Where this came from, so L3 can put it in a recording's metadata. */
  readonly source: { readonly url: string };
};

/**
 * A transaction hash becomes an upstream `Tx` plus the block coordinates needed to re-execute it.
 *
 * THE ORDER IS LOAD-BEARING and every step of it can refuse:
 *
 *   1. `fetchSettledTx`       -> `SettledTransactionNotFound` (L0's, unchanged)
 *   2. `fetchSettledTxEffect` -> the same, naming `getTxEffect`, so a transaction whose body is
 *                                retained and whose effect is not is distinguishable from one
 *                                where the reverse is true
 *   3. `getBlockData`         -> `SettlingBlockUnavailable`
 *   4. contract resolution    -> `MissingContractArtifact`, by name, at one of three stages
 *
 * Nothing partial is returned from any of them. A caller either gets a `SettledTransaction` whose
 * every contract has bytecode, or an error that says which question failed.
 */
export async function fetchSettledTransaction(
  client: ReplayNodeClient,
  txHash: TxHash,
): Promise<SettledTransaction> {
  const hashText = txHash.toString();

  const tx = await client.fetchSettledTx(txHash);
  const txEffect = await client.fetchSettledTxEffect(txHash);

  // `l2BlockNumber` is upstream's branded `BlockNumber`, which IS a `BlockParameter`, so the
  // settling block is asked for with the very value the effect named rather than a number this
  // module re-made. The plain `number` below is for the record, not for the call.
  const blockData = await client.getBlockData(txEffect.l2BlockNumber);
  const blockNumber = Number(txEffect.l2BlockNumber);
  if (blockData === undefined || blockData === null) {
    throw new SettlingBlockUnavailable(blockNumber, hashText, client.url);
  }

  const targets = publicCallTargets(tx);
  const contracts = await resolvePublicContracts(client, targets, {
    refuseUnknown: true,
    txHash: hashText,
  });

  return {
    txHash: hashText,
    tx,
    txEffect,
    l2BlockNumber: blockNumber,
    l2BlockHash: txEffect.l2BlockHash.toString(),
    txIndexInBlock: txEffect.txIndexInBlock,
    blockData,
    revertCode: txEffect.data.revertCode.getCode(),
    publicHalf: declarePublicHalf(tx),
    privateHalf: declarePrivateHalf({ origin: 'settled-chain', txEffect: txEffect.data }),
    contracts,
    source: { url: client.url },
  };
}
