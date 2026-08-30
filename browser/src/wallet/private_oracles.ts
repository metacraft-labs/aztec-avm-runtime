// M35 — the private-execution oracle handler.
//
// WHAT THIS FILE IS, AND WHAT IT DELIBERATELY IS NOT.
//
// `buildACIRCallback` (vendored, RI-97) turns `ORACLE_REGISTRY` plus a handler OBJECT into the
// `ACIRCallback` the ACVM calls: it parses each oracle key by upstream's `aztec_{scope}_{method}`
// convention, deserialises the ACVM input slots through the registry's declared `TypeMapping`s,
// calls `handler[method](...positional)`, and serialises the return the same way. So the WIRE is
// upstream's and vendored byte for byte; the HANDLER is ours and is this file.
//
// THE RULE THIS FILE EXISTS TO ENFORCE, and it is the campaign's oldest:
//
//   **Every unimplemented oracle refuses BY NAME.** A missing oracle must never return a plausible
//   value. This is the one milestone where violating it would be least visible — a fabricated note
//   or nullifier produces a transaction that *looks* valid, parses, settles, and is wrong.
//
// So there is no default branch, no `?? 0`, no empty array standing in for "I do not know". Every
// one of the registry's oracles is present on the handler; the ones this milestone does not serve
// throw an `OracleUnimplemented` that names the oracle AND says what would have to exist for it to
// stop refusing — which is a tier for some, a milestone for others, and for four of them a
// MEASUREMENT (see `EPHEMERAL_RETURN_ORACLES`). Every refused oracle has a reason and the check
// asserts that; what the reason contains is not uniform, and claiming it was would be a sentence
// nothing re-derives. A `throw` inside a foreign-call handler aborts the ACVM's execution — measured
// on Token's private `transfer`, which stops at the first oracle it needs that this file refuses —
// so a contract that reaches an unserved oracle fails loudly at the instruction that needed it.
//
// THE PARTITION IS DERIVED, NOT TYPED. `ORACLE_NAMES` is `Object.keys(ORACLE_REGISTRY)` — the
// vendored registry's own keys — so a sixty-ninth oracle upstream adds is REFUSED on the day the
// anchor moves, with no edit here. `ORACLE_REFUSING` is that set minus the served one. The two are
// asserted disjoint and summing to the re-derived count by
// `verify_oracle_coverage_is_measured`, and reconciled against what the handler object actually
// carries by `assertOracleSurfaceMatchesDeclaration` at construction — because a list a check reads
// and an object a contract calls are two things that drift. That is M34's `DEV_WALLET_SERVED`
// finding, which was that three declarations of one partition are three things to keep in step.
//
// SCOPE MARKERS. `assertHandlerSupportsScope` in the vendored callback checks `'isMisc' in handler`,
// `'isUtility' in handler` and `'isPrivate' in handler` before dispatching, and upstream's own
// `PrivateExecutionOracle extends UtilityExecutionOracle`, so a private-execution handler carries
// all three. Ours does, and a `misc`/`utl`/`prv` name that is refused is refused by THIS file rather
// than by the scope guard — which matters, because M34 learned the hard way that a refusal produced
// by somebody else's codec is not the refusal you were measuring.

import { Fr } from '@aztec/foundation/curves/bn254';
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { MAX_FR_CALLDATA_TO_ALL_ENQUEUED_CALLS } from '@aztec/constants';
import { siloNullifier } from '@aztec/stdlib/hash';
import { poseidon2HashWithSeparator } from '@aztec/foundation/crypto/poseidon';
// The address derivation is UPSTREAM'S OWN, not a re-implementation. `computeContractAddressFromInstance`
// is the TypeScript side of the same computation `ContractInstance::to_address()` performs inside the
// circuit, so the guard below and `aztec-nr`'s `assert_eq` are two evaluations of one function rather
// than two functions that ought to agree. Re-implementing it here would have produced a guard that
// passes exactly when it is wrong in the same way the handler is.
import { computeContractAddressFromInstance } from '@aztec/stdlib/contract';
import type { PublicKeys } from '@aztec/stdlib/keys';

import { ORACLE_REGISTRY } from '../vendor/pxe/contract_function_simulator/oracle/oracle_registry.ts';
import { ORACLE_VERSION_MAJOR, ORACLE_VERSION_MINOR } from '../vendor/pxe/oracle_version.ts';
import { Option } from '../vendor/pxe/contract_function_simulator/noir-structs/option.ts';
import { EphemeralArrayService } from '../vendor/pxe/contract_function_simulator/ephemeral_array_service.ts';
import { TransientArrayService } from '../vendor/pxe/contract_function_simulator/transient_array_service.ts';

/** Upstream's own oracle names, read from the vendored registry rather than typed here. */
export const ORACLE_NAMES: readonly string[] = Object.freeze(Object.keys(ORACLE_REGISTRY).sort());

/** The environment's oracle version, read from the vendored `oracle_version.ts` rather than typed. */
export const ORACLE_ENVIRONMENT_VERSION = Object.freeze({
  major: ORACLE_VERSION_MAJOR,
  minor: ORACLE_VERSION_MINOR,
});

/**
 * The oracles M35 serves — TIER 1, the in-memory bookkeeping family, plus the two execution-state
 * sinks and deterministic entropy.
 *
 * Declared as a list rather than derived from the handler object, for the reason M34's review
 * recorded: the object is built inside a factory that closes over per-execution state, so a check
 * cannot derive the list from it. `assertOracleSurfaceMatchesDeclaration` reconciles the two in both
 * directions at construction and throws naming the difference.
 */
export const ORACLE_IMPLEMENTED: readonly string[] = Object.freeze(
  [
    // misc — the three that are not Aztec-specific
    'aztec_misc_assertCompatibleOracleVersion',
    'aztec_misc_getRandomField',
    'aztec_misc_log',
    // tier 2's first rung — the contract instance directory. Served from what the wallet HOLDS,
    // and refused by name for an address it does not. See `ContractInstanceNotHeld`.
    'aztec_utl_getContractInstance',
    // capsules — a per-(contract, slot) field store, scoped
    'aztec_utl_setCapsule',
    'aztec_utl_getCapsule',
    'aztec_utl_deleteCapsule',
    'aztec_utl_copyCapsule',
    // ephemeral arrays — one service per call frame
    'aztec_utl_pushEphemeral',
    'aztec_utl_popEphemeral',
    'aztec_utl_getEphemeral',
    'aztec_utl_setEphemeral',
    'aztec_utl_getEphemeralLen',
    'aztec_utl_removeEphemeral',
    'aztec_utl_clearEphemeral',
    // transient arrays — one service per top-level call, keyed by (contract, slot)
    'aztec_utl_pushTransient',
    'aztec_utl_popTransient',
    'aztec_utl_getTransient',
    'aztec_utl_setTransient',
    'aztec_utl_getTransientLen',
    'aztec_utl_removeTransient',
    'aztec_utl_clearTransient',
    // execution-state sinks — no return, so there is no value to fabricate
    'aztec_utl_setContractSyncCacheInvalid',
    'aztec_utl_emitOffchainEffect',
    // the execution cache
    'aztec_prv_setHashPreimage',
    'aztec_prv_getHashPreimage',
    'aztec_prv_assertValidPublicCalldata',
    // the notify* family and the two questions answered from it
    'aztec_prv_notifyCreatedNote',
    'aztec_prv_notifyNullifiedNote',
    'aztec_prv_notifyCreatedNullifier',
    'aztec_prv_notifyCreatedContractClassLog',
    'aztec_prv_notifyRevertiblePhaseStart',
    'aztec_prv_isNullifierPending',
    'aztec_prv_isExecutionInRevertiblePhase',
  ].sort(),
);

/** Everything else, DERIVED. A new upstream oracle lands here without an edit. */
export const ORACLE_REFUSING: readonly string[] = Object.freeze(
  ORACLE_NAMES.filter(n => !ORACLE_IMPLEMENTED.includes(n)),
);

/**
 * Why each refused oracle is refused, and what would have to exist for it to stop refusing.
 *
 * A refusal that says only "not implemented" is a refusal a reader cannot act on, so each reason
 * names the TIER (the milestone's own four: in-memory, adapters, crypto, `callPrivateFunction`) and
 * the milestone that owns it. Four of these reasons are MEASUREMENTS rather than plans — see
 * `EPHEMERAL_RETURN_ORACLES` below.
 */
export const ORACLE_REFUSAL_REASONS: Readonly<Record<string, string>> = Object.freeze({
  // ---- tier 2, the adapters over exports this runtime already has -----------------------------
  // `aztec_utl_getContractInstance` WAS HERE and is now served — tier 2's first rung. It is the
  // one refusal this campaign removed by building the thing rather than by lowering the bar, and
  // what replaced it is not "always answer": an address the wallet does not hold still refuses, by
  // name, through `ContractInstanceNotHeld`. See section 3a of PRIVATE-EXECUTION.md.
  aztec_utl_getNoteHashMembershipWitness:
    'tier 2 (adapters): needs a value-to-index lookup in the note-hash tree, and ' +
    'ResidentMerkleWriteOperations.findLeafIndices REFUSES by name (RI-67). A sibling path can only ' +
    'be taken by INDEX here',
  aztec_utl_getBlockHashMembershipWitness: 'tier 2 (adapters): an archive membership witness',
  aztec_utl_areBlockHashesInArchive:
    'tier 2 (adapters), and its return carries an EPHEMERAL_ARRAY — see the deterministic-slot ' +
    'measurement in PRIVATE-EXECUTION.md section 5',
  aztec_utl_getNullifierMembershipWitness: 'tier 2 (adapters): a nullifier-tree membership witness',
  aztec_utl_getLowNullifierMembershipWitness: 'tier 2 (adapters): a nullifier-tree low-leaf witness',
  aztec_utl_getPublicDataWitness: 'tier 2 (adapters): a public-data-tree membership witness',
  aztec_utl_getBlockHeader: 'tier 2 (adapters): a historical block header from the chain this node produced',
  aztec_utl_getAuthWitness:
    'tier 2 (adapters): an authwit store in the wallet. WalletSchema.createAuthWit refuses in M34 ' +
    'for the same reason, so serving this one would be a value with no producer',
  aztec_utl_getPublicKeysAndPartialAddress:
    'tier 2 (adapters): the wallet derives its own accounts\' keys (RI-96) but has no directory of ' +
    'anybody else\'s',
  aztec_utl_doesNullifierExist: 'tier 2 (adapters): ResidentMerkleDb.nullifierExists is the primitive',
  aztec_utl_getL1ToL2MembershipWitnessV2: 'tier 2 (adapters): an L1-to-L2 message-tree witness',
  aztec_utl_getFromPublicStorage: 'tier 2 (adapters): ResidentMerkleDb.readPublicDataLeaf is the primitive',
  aztec_utl_getResolvedTxs:
    'tier 2 (adapters), and its return carries an EPHEMERAL_ARRAY — see PRIVATE-EXECUTION.md section 5',
  aztec_utl_getTxEffect: 'tier 2 (adapters): the chain\'s own transaction effects',
  aztec_utl_getTxEffects:
    'tier 2 (adapters), and its return carries an EPHEMERAL_ARRAY — see PRIVATE-EXECUTION.md section 5',
  aztec_utl_getKeyValidationRequest:
    'tier 2 (adapters): a key-validation request needs the app-siloed nullifier secret of an account ' +
    'this wallet holds; the derivation exists (RI-96) and the siloing does not',
  // ---- the fact store, refused for a MEASURED reason rather than a planned one ----------------
  aztec_utl_recordFact:
    'the fact store is not served: its collection type is round-tripped through an EphemeralArray, ' +
    'whose slot allocation calls Fr.random() — ambient randomness, which this wallet\'s third design ' +
    'property forbids. See PRIVATE-EXECUTION.md section 5',
  aztec_utl_deleteFactCollection: 'the fact store is not served — see aztec_utl_recordFact',
  aztec_utl_getFactCollection: 'the fact store is not served — see aztec_utl_recordFact',
  aztec_utl_getFactCollectionsByType: 'the fact store is not served — see aztec_utl_recordFact',
  // ---- tier 3, crypto --------------------------------------------------------------------------
  aztec_utl_decryptAes128:
    'tier 3 (crypto): AES-128 is not an export of avm.wasm — measured, there is no aes symbol in the ' +
    'linked module at all — and WebCrypto\'s AES-CBC is the intended overlay',
  aztec_utl_getSharedSecrets:
    'tier 3 (crypto): grumpkin ECDH over avm_grumpkin_mul, and its return carries an EPHEMERAL_ARRAY',
  // ---- tier 4, structural ----------------------------------------------------------------------
  aztec_prv_callPrivateFunction:
    'tier 4 (structural): recursion back into the simulator, with a nested call frame, its own ' +
    'ephemeral-array service and its own side-effect counter range',
  aztec_utl_callUtilityFunction: 'tier 4 (structural): recursion into a utility function',
  aztec_utl_getUtilityContext:
    'tier 4 (structural): there is no utility context in a private call frame, and inventing one is ' +
    'exactly the plausible default this milestone refuses',
  aztec_prv_resolveCustomRequest: 'tier 4 (structural): a contract-defined request with no registered resolvers',
  // ---- M36 -------------------------------------------------------------------------------------
  aztec_utl_getNotes: 'note discovery — M36',
  aztec_utl_getPendingTaggedLogsV2: 'note discovery — M36',
  aztec_utl_getLogsByTagV2: 'note discovery — M36',
  aztec_utl_validateAndStoreEnqueuedNotesAndEvents: 'note discovery — M36',
  aztec_prv_getAppTaggingSecret: 'tagging — M36',
  aztec_prv_getNextTaggingIndex: 'tagging — M36',
  aztec_prv_getSenderForTags: 'tagging — M36',
  aztec_prv_resolveTaggingStrategy: 'tagging — M36',
});

/**
 * The oracles whose RETURN type carries an `EphemeralArray`, derived from the vendored registry's
 * own `label` strings rather than listed here.
 *
 * This matters and it is a measurement, not a caveat. `EphemeralArray.materializeSlot` — the
 * serialisation path for an output-mode array — calls `EphemeralArrayService.newArray`, which calls
 * `allocateSlot`, which is `do { slot = Fr.random(); } while (...)`. So **serialising any of these
 * returns reads ambient entropy**, and a recording made through one of them does not replay
 * identically. `DEV-WALLET.md` section 1 states no-ambient-randomness as the design property that is
 * easiest to "harden" away by accident; this is the first place in the campaign where upstream's own
 * code sits on the other side of it.
 */
export const EPHEMERAL_RETURN_ORACLES: readonly string[] = Object.freeze(
  ORACLE_NAMES.filter(name => {
    const entry = (ORACLE_REGISTRY as Record<string, { returnType?: { kind?: string; label?: string } }>)[name];
    const rt = entry?.returnType;
    if (!rt) {
      return false;
    }
    // THE NEEDLE COMES FROM THE ARTEFACT AND THE FIRST ONE DID NOT. `EPHEMERAL_ARRAY`'s label is
    // spelled `ephemeral-array(...)` with a HYPHEN and its `kind` is `'ephemeral-array'`; a first
    // draft here matched `ephemeral_array` with an underscore and returned **zero**, which is this
    // campaign's oldest needle defect in the direction that reads as good news. Both spellings are
    // read off the vendored mapping, and `ORACLE_EPHEMERAL_RETURN_LABELS` below prints the label of
    // every one that matched so the count can be audited rather than believed.
    return rt.kind === 'ephemeral-array' || (rt.label?.includes('ephemeral-array(') ?? false);
  }),
);

/** The matched labels, so the count above is auditable from the artefact rather than trusted. */
export const ORACLE_EPHEMERAL_RETURN_LABELS: Readonly<Record<string, string>> = Object.freeze(
  Object.fromEntries(
    EPHEMERAL_RETURN_ORACLES.map(name => [
      name,
      (ORACLE_REGISTRY as Record<string, { returnType?: { label?: string } }>)[name]?.returnType?.label ?? '?',
    ]),
  ),
);

/** Raised when a contract calls an oracle this milestone does not serve. Never a return value. */
export class OracleUnimplemented extends Error {
  constructor(
    readonly oracle: string,
    readonly reason: string,
  ) {
    super(
      `OracleUnimplemented: the CodeTracer dev wallet does not serve the oracle '${oracle}': ${reason}. ` +
        `A missing oracle refuses by name rather than returning a plausible value, because a fabricated ` +
        `note or nullifier produces a transaction that looks valid.`,
    );
    this.name = 'OracleUnimplemented';
  }
}

/**
 * Raised when a contract asks for an instance this wallet does not hold.
 *
 * **THIS IS NOT `OracleUnimplemented`, AND CONFLATING THEM WOULD MAKE THE LEDGER LIE.** The oracle
 * IS served; the wallet simply has no instance at that address. Those are different facts about
 * the runtime — the first says "build tier 2", the second says "register the contract first" — and
 * a reader who cannot tell them apart will go and build the wrong thing. So the error names the
 * oracle, the address that missed, and HOW MANY the directory holds, because "not held" over an
 * empty directory and "not held" over a directory of four are different situations.
 */
export class ContractInstanceNotHeld extends Error {
  constructor(
    readonly oracle: string,
    readonly address: string,
    readonly heldCount: number,
  ) {
    super(
      `ContractInstanceNotHeld: '${oracle}' is served, but this wallet holds no contract instance ` +
        `at ${address} (the directory holds ${heldCount}). The wallet answers this oracle from the ` +
        `instances it was GIVEN — a chain it produced or registered into — and never from a ` +
        `zero-filled preimage, because a fabricated instance produces a transaction that looks ` +
        `valid. Register the contract with the wallet before executing against it.`,
    );
    this.name = 'ContractInstanceNotHeld';
  }
}

/** Raised when the executing bytecode's oracle version is not compatible with this environment. */
export class OracleVersionIncompatible extends Error {
  constructor(
    readonly contractMajor: number,
    readonly contractMinor: number,
    readonly environmentMajor: number,
    readonly environmentMinor: number,
  ) {
    super(
      `OracleVersionIncompatible: the contract was compiled against Aztec.nr oracle version ` +
        `${contractMajor}.${contractMinor} and this environment implements ${environmentMajor}.${environmentMinor}. ` +
        `A major-version disagreement is breaking; see the anchor's own oracle_version.ts.`,
    );
    this.name = 'OracleVersionIncompatible';
  }
}

/** One entry in the ordered ledger of what the executing bytecode asked for. */
export interface OracleCall {
  readonly seq: number;
  readonly oracle: string;
  /**
   * THREE OUTCOMES, AND THE THIRD IS NOT A SHADE OF THE SECOND.
   *
   *   `served`       the oracle answered.
   *   `refused`      this wallet does not serve this oracle at all — `OracleUnimplemented`. A fact
   *                  about the PARTITION, true for every argument, and the thing whose set must
   *                  equal `ORACLE_REFUSING`.
   *   `unavailable`  the oracle IS served and had no answer for THIS argument —
   *                  `ContractInstanceNotHeld`. A fact about the wallet's DATA, not its surface.
   *
   * The third was added when tier 2's first rung landed, and collapsing it into `refused` was tried
   * first: it makes one oracle appear in both the served and the refused sets of a single run, so
   * "the served and refusing sets are disjoint" — an invariant about the partition — starts failing
   * because of a directory lookup. The sets were never the same kind of thing; one outcome value
   * was hiding that.
   */
  readonly outcome: 'served' | 'refused' | 'unavailable';
  readonly detail: string;
}

export interface PrivateOracleOptions {
  /**
   * The contract whose frame this is. Capsules and transient arrays are keyed by it, and a contract
   * asking for another contract's slice is refused by name — upstream's own `#assertOwnContract`.
   */
  readonly contractAddress: AztecAddress;
  /**
   * The entropy seed. **An argument, never generated** — the same discipline `dev_keys.ts` applies
   * to key derivation, applied to `getRandomField`, so a recording replays identically. DD-4's rule
   * for clocks, for entropy.
   */
  readonly entropySeed: Fr;
  /** Optional sink for `aztec_misc_log`, so a contract's debug_log is visible rather than dropped. */
  readonly writeLine?: (line: string) => void;
  /**
   * The contract instances this wallet HOLDS, for `aztec_utl_getContractInstance` — tier 2's first
   * rung, and the oracle every real private function reaches after the version check.
   *
   * **THE BOUNDARY, STATED HERE BECAUSE IT IS THE WHOLE MEANING OF THE ORACLE.** This is a
   * directory of instances the wallet was GIVEN — a chain we produced, registered into, or
   * derived. It is not an archiver and it is not a view of a chain we synced. An address that is
   * not in it is refused by name (`ContractInstanceNotHeld`), never answered with a zero-filled
   * preimage, because a zero-filled instance is exactly the plausible default that makes a
   * transaction look valid and be wrong.
   *
   * Omitting it entirely is legal and means the wallet holds NOTHING: every address then refuses.
   * That is the honest default — an empty directory is a directory, and it is not the same object
   * as an oracle that does not exist.
   */
  readonly contractInstances?: readonly HeldContractInstance[];
}

/**
 * One instance the wallet holds: an address, and the six fields the vendored `CONTRACT_INSTANCE`
 * mapping serialises.
 *
 * **THE ADDRESS IS NOT A SEVENTH INDEPENDENT FIELD, AND THE CIRCUIT IS WHAT SAYS SO.**
 * `aztec-nr`'s own `get_contract_instance` is:
 *
 * ```
 * let instance = unsafe { get_contract_instance_internal(address) };
 * assert_eq(instance.to_address(), address);
 * ```
 *
 * — so the CIRCUIT re-derives the address from the preimage it was handed and constrains it. That
 * is unusual and it is worth saying plainly: for this one oracle the "plausible default" a wrong
 * handler would return is caught by the thing under test rather than by us. A directory whose
 * address and preimage disagree does not silently produce a wrong transaction; it fails the
 * circuit's own assertion. `assertHeldInstancesAreSelfConsistent` re-derives the same relation on
 * OUR side too, at construction, so the disagreement is named here before the ACVM names it four
 * layers down.
 */
export interface HeldContractInstance {
  /** The deployment address, which must equal what the preimage below derives to. */
  readonly address: AztecAddress;
  readonly salt: Fr;
  readonly deployer: AztecAddress;
  readonly originalContractClassId: Fr;
  readonly initializationHash: Fr;
  readonly immutablesHash: Fr;
  readonly publicKeys: PublicKeys;
}

export interface PrivateOracleHandle {
  /** The object `buildACIRCallback` dispatches into. */
  readonly handler: Record<string, unknown>;
  /** Everything the bytecode asked for, in order, served and refused alike. */
  calls(): readonly OracleCall[];
  /** The oracle version the executing bytecode declared, or `undefined` if it never declared one. */
  contractVersion(): { major: number; minor: number } | undefined;
  /** The notes the frame created, the nullifiers it emitted, and the offchain effects it emitted. */
  effects(): {
    createdNotes: readonly { owner: string; storageSlot: string; noteHash: string; counter: number }[];
    createdNullifiers: readonly string[];
    nullifiedNotes: readonly { innerNullifier: string; noteHash: string; counter: number }[];
    contractClassLogs: readonly { contractAddress: string; emittedLength: number; counter: number }[];
    offchainEffects: readonly string[][];
    randomFields: number;
  };
}

/**
 * Reconciles the declared partition against the object that actually answers, in both directions,
 * and throws naming the difference. Exported so a check can exercise it over the BUILT bundle with
 * a doctored list and see it fire — a guard nobody has seen refuse is a guard nobody has tested.
 */
export function assertOracleSurfaceMatchesDeclaration(methodNames: readonly string[]): void {
  const carried = new Set(methodNames);
  const wanted = ORACLE_NAMES.map(oracleMethodName);
  const missing = wanted.filter(m => !carried.has(m));
  const extra = [...carried].filter(m => !wanted.includes(m));
  if (missing.length > 0 || extra.length > 0) {
    throw new Error(
      `the oracle handler does not match the registry: missing [${missing.join(', ')}], ` +
        `undeclared [${extra.join(', ')}]`,
    );
  }
  const overlap = ORACLE_IMPLEMENTED.filter(n => ORACLE_REFUSING.includes(n));
  if (overlap.length > 0) {
    throw new Error(`the implemented and refusing sets are not disjoint: [${overlap.join(', ')}]`);
  }
  if (ORACLE_IMPLEMENTED.length + ORACLE_REFUSING.length !== ORACLE_NAMES.length) {
    throw new Error(
      `the implemented and refusing sets do not sum to the registry: ` +
        `${ORACLE_IMPLEMENTED.length} + ${ORACLE_REFUSING.length} !== ${ORACLE_NAMES.length}`,
    );
  }
  const unexplained = ORACLE_REFUSING.filter(n => !ORACLE_REFUSAL_REASONS[n]);
  if (unexplained.length > 0) {
    throw new Error(`refused oracles with no declared reason: [${unexplained.join(', ')}]`);
  }
}

/**
 * Re-derives every held instance's address from its own preimage and throws naming any that
 * disagrees.
 *
 * **WHY THIS EXISTS WHEN THE CIRCUIT ALREADY CHECKS IT.** `aztec-nr`'s `get_contract_instance`
 * asserts `instance.to_address() == address`, so an inconsistent directory cannot produce a wrong
 * transaction — it produces a FAILED one. But it fails inside the ACVM, as a solver error about a
 * constraint, four layers from the directory that caused it; M35's own header records what that
 * costs (`Error awaiting foreign_call_handler`, eleven words naming nothing). This names the
 * address, both derivations and the entry, at the point the directory is handed over.
 *
 * It is deliberately NOT a re-implementation: it calls upstream's own
 * `computeContractAddressFromInstance`, the TypeScript half of the circuit's `to_address()`.
 *
 * Async because that derivation is — it is a poseidon2 chain plus a grumpkin scalar multiplication,
 * and under this build both go through `avm.wasm`.
 */
export async function assertHeldInstancesAreSelfConsistent(
  instances: readonly HeldContractInstance[],
): Promise<void> {
  const seen = new Set<string>();
  for (const [i, held] of instances.entries()) {
    const key = held.address.toString();
    if (seen.has(key)) {
      throw new Error(
        `the contract instance directory holds two entries for ${key}; an address is a key and a ` +
          `second entry for it would silently shadow the first`,
      );
    }
    seen.add(key);
    const derived = await computeContractAddressFromInstance({
      salt: held.salt,
      deployer: held.deployer,
      currentContractClassId: held.originalContractClassId,
      originalContractClassId: held.originalContractClassId,
      initializationHash: held.initializationHash,
      immutablesHash: held.immutablesHash,
      publicKeys: held.publicKeys,
      version: 2,
    } as Parameters<typeof computeContractAddressFromInstance>[0]);
    if (!derived.equals(held.address)) {
      throw new Error(
        `contract instance directory entry ${i} is not self-consistent: it is filed under ` +
          `${key} but its own preimage derives to ${derived.toString()}. The circuit's ` +
          `get_contract_instance asserts exactly this equality, so this entry would fail the ACVM ` +
          `as an unsatisfied constraint rather than as a directory problem.`,
      );
    }
  }
}

/** `aztec_{scope}_{method}` -> `method`, by upstream's own regex rather than by a `split`. */
export function oracleMethodName(oracleKey: string): string {
  const m = oracleKey.match(/^aztec_(\w+?)_(.+)$/);
  if (!m) {
    throw new Error(`oracle key '${oracleKey}' does not follow the aztec_{scope}_{method} convention`);
  }
  return m[2];
}

const CAPSULE_KEY = (contract: AztecAddress, slot: Fr, scope: AztecAddress) =>
  `${contract.toString()}:${scope.toString()}:${slot.toString()}`;

/**
 * Builds the handler.
 *
 * Every served method is a closure over per-frame state; every unserved one is a thunk that throws
 * `OracleUnimplemented`. Both kinds record into the same ordered ledger, so "every oracle call
 * visible" — `DEV-WALLET.md` section 1's first design property — covers refusals too, which is the
 * half that matters when a private execution stops.
 */
export function createPrivateOracleHandler(options: PrivateOracleOptions): PrivateOracleHandle {
  const contract = options.contractAddress;
  // The instance directory, keyed by address string. Built from the option rather than mutated, so
  // a handler's directory is fixed for the life of the frame — a contract that could ADD to it
  // mid-execution could answer its own question.
  const instanceDirectory = new Map<string, HeldContractInstance>(
    (options.contractInstances ?? []).map(h => [h.address.toString(), h]),
  );
  const capsules = new Map<string, Fr[]>();
  const ephemeral = new EphemeralArrayService();
  const transient = new TransientArrayService();
  const executionCache = new Map<string, Fr[]>();
  const pendingNullifiers = new Set<string>();
  const pendingNotes: { noteHash: Fr; counter: number }[] = [];
  let totalPublicCalldata = 0;
  const createdNotes: { owner: string; storageSlot: string; noteHash: string; counter: number }[] = [];
  const createdNullifiers: string[] = [];
  const nullifiedNotes: { innerNullifier: string; noteHash: string; counter: number }[] = [];
  const contractClassLogs: { contractAddress: string; emittedLength: number; counter: number }[] = [];
  const offchainEffects: string[][] = [];
  const calls: OracleCall[] = [];
  let seq = 0;
  let contractVersion: { major: number; minor: number } | undefined;
  let inRevertiblePhase = false;
  let minRevertibleSideEffectCounter = 0;
  let randomCounter = 0;

  const record = (oracle: string, outcome: 'served' | 'refused' | 'unavailable', detail: string) => {
    calls.push({ seq: seq++, oracle, outcome, detail });
  };

  // Upstream's `#recordNullifier`, which is the one place a nullifier enters the pending set — so
  // the duplicate refusal is written once and cannot be forgotten at a second call site.
  const recordNullifier = (siloed: Fr, oracle: string) => {
    const key = siloed.toString();
    if (pendingNullifiers.has(key)) {
      throw new Error(
        `${oracle}: duplicate siloed nullifier ${key} emitted by contract ${contract.toString()}`,
      );
    }
    pendingNullifiers.add(key);
  };

  // Upstream's own guard: a contract may only reach its own slice of the store.
  const assertOwnContract = (oracle: string, address: AztecAddress) => {
    if (!address.equals(contract)) {
      throw new Error(
        `${oracle}: contract ${address.toString()} is not allowed to access ${contract.toString()}'s store`,
      );
    }
  };

  const served: Record<string, (...args: never[]) => unknown> = {
    // ---- misc ---------------------------------------------------------------------------------
    assertCompatibleOracleVersion(major: number, minor: number): void {
      // THE THROW COMES BEFORE THE RECORD, which is upstream's order and is not cosmetic: a version
      // this environment REJECTED must not then be reported as the version it is serving. The ledger
      // still carries the call, because a refusal that leaves no trace is the thing this wallet's
      // first design property forbids.
      record(
        'aztec_misc_assertCompatibleOracleVersion',
        major === ORACLE_ENVIRONMENT_VERSION.major ? 'served' : 'refused',
        `contract=${major}.${minor} environment=${ORACLE_ENVIRONMENT_VERSION.major}.${ORACLE_ENVIRONMENT_VERSION.minor}`,
      );
      if (major !== ORACLE_ENVIRONMENT_VERSION.major) {
        throw new OracleVersionIncompatible(
          major,
          minor,
          ORACLE_ENVIRONMENT_VERSION.major,
          ORACLE_ENVIRONMENT_VERSION.minor,
        );
      }
      contractVersion = { major, minor };
    },

    // Deterministic entropy. `crypto.getRandomValues` would be the obvious implementation and is
    // exactly what `DEV-WALLET.md` section 1 forbids: the seed is an argument and the stream is a
    // counter hashed with it, so the same seed produces the same fields in the same order, twice.
    async getRandomField(): Promise<Fr> {
      const index = randomCounter++;
      const field = await poseidon2HashWithSeparator([options.entropySeed, new Fr(BigInt(index))], 0);
      record('aztec_misc_getRandomField', 'served', `index=${index}`);
      return field;
    },

    log(level: number, message: string, fieldsSize: number, fields: Fr[]): void {
      const rendered = fields
        .slice(0, fieldsSize)
        .map(f => f.toString())
        .join(' ');
      record('aztec_misc_log', 'served', `level=${level} fields=${fieldsSize}`);
      options.writeLine?.(`[contract] ${message}${rendered ? ' ' + rendered : ''}`);
    },

    // ---- tier 2, rung 1: the contract instance directory ----------------------------------------
    //
    // THE ORACLE EVERY REAL PRIVATE FUNCTION REACHES AFTER THE VERSION CHECK. Until this method
    // existed, `Token.transfer`, `Token.mint_to_private` and `PrivateVoting.cast_vote` all stopped
    // here — three programs, two contracts, three bytecodes, one rung.
    //
    // WHAT "SERVED" MEANS HERE, AND WHAT IT DOES NOT. It means: answered FROM THE DIRECTORY THIS
    // WALLET WAS GIVEN. An address the wallet does not hold throws `ContractInstanceNotHeld` — a
    // refusal, recorded as one, distinct from `OracleUnimplemented` because the two say different
    // things about what to build next. There is no fallback, no zero-filled preimage and no
    // `Option::none()` shape to hide behind: the oracle's declared return is a bare
    // `CONTRACT_INSTANCE`, so "I do not know" has nowhere to go in the type and must be a throw.
    getContractInstance(address: AztecAddress): {
      salt: Fr;
      deployer: AztecAddress;
      originalContractClassId: Fr;
      initializationHash: Fr;
      immutablesHash: Fr;
      publicKeys: PublicKeys;
    } {
      const held = instanceDirectory.get(address.toString());
      if (!held) {
        record(
          'aztec_utl_getContractInstance',
          'unavailable',
          `no instance held at ${address.toString()}; the directory holds ${instanceDirectory.size}`,
        );
        throw new ContractInstanceNotHeld(
          'aztec_utl_getContractInstance',
          address.toString(),
          instanceDirectory.size,
        );
      }
      record(
        'aztec_utl_getContractInstance',
        'served',
        `address=${address.toString()} classId=${held.originalContractClassId.toString()}`,
      );
      // The SIX fields the vendored CONTRACT_INSTANCE mapping declares, and only those. `address`
      // is not among them — the nr-side struct does not carry it, because the circuit derives it.
      return {
        salt: held.salt,
        deployer: held.deployer,
        originalContractClassId: held.originalContractClassId,
        initializationHash: held.initializationHash,
        immutablesHash: held.immutablesHash,
        publicKeys: held.publicKeys,
      };
    },

    // ---- capsules -----------------------------------------------------------------------------
    setCapsule(contractAddress: AztecAddress, slot: Fr, capsule: Fr[], scope: AztecAddress): void {
      assertOwnContract('aztec_utl_setCapsule', contractAddress);
      capsules.set(CAPSULE_KEY(contractAddress, slot, scope), [...capsule]);
      record('aztec_utl_setCapsule', 'served', `slot=${slot.toString()} len=${capsule.length}`);
    },

    getCapsule(contractAddress: AztecAddress, slot: Fr, tSize: number, scope: AztecAddress): Option<Fr[]> {
      assertOwnContract('aztec_utl_getCapsule', contractAddress);
      const values = capsules.get(CAPSULE_KEY(contractAddress, slot, scope));
      record('aztec_utl_getCapsule', 'served', `slot=${slot.toString()} present=${values !== undefined}`);
      return values ? Option.some(values) : Option.none({ length: tSize });
    },

    deleteCapsule(contractAddress: AztecAddress, slot: Fr, scope: AztecAddress): void {
      assertOwnContract('aztec_utl_deleteCapsule', contractAddress);
      capsules.delete(CAPSULE_KEY(contractAddress, slot, scope));
      record('aztec_utl_deleteCapsule', 'served', `slot=${slot.toString()}`);
    },

    copyCapsule(
      contractAddress: AztecAddress,
      srcSlot: Fr,
      dstSlot: Fr,
      numEntries: number,
      scope: AztecAddress,
    ): void {
      assertOwnContract('aztec_utl_copyCapsule', contractAddress);
      // ENTRY BY ENTRY AT CONSECUTIVE SLOTS — a capsule is one T per slot, so `numEntries` SLOTS
      // move rather than `numEntries` fields of one slot.
      //
      // AND THE DIRECTION MATTERS, WHICH A FIRST VERSION OF THIS GOT WRONG. Upstream's
      // `CapsuleStore.copyCapsule` reverses the index order when `srcSlot < dstSlot`, and its own
      // comment says why: with the destination AHEAD of the source the ranges overlap, and a forward
      // walk overwrites source entries before it reads them. A forward-only copy is correct for
      // every disjoint range and silently wrong for an overlapping one — which is the "nearly right"
      // shape this milestone exists to refuse, in a store a contract reads back.
      const indexes = Array.from({ length: numEntries }, (_v, i) => i);
      if (srcSlot.lt(dstSlot)) {
        indexes.reverse();
      }
      for (const i of indexes) {
        const from = srcSlot.add(new Fr(BigInt(i)));
        const src = CAPSULE_KEY(contractAddress, from, scope);
        const dst = CAPSULE_KEY(contractAddress, dstSlot.add(new Fr(BigInt(i))), scope);
        const value = capsules.get(src);
        if (value === undefined) {
          throw new Error(`aztec_utl_copyCapsule: no capsule at source slot ${from.toString()}`);
        }
        capsules.set(dst, [...value]);
      }
      record(
        'aztec_utl_copyCapsule',
        'served',
        `entries=${numEntries} order=${srcSlot.lt(dstSlot) ? 'backward' : 'forward'}`,
      );
    },

    // ---- ephemeral arrays (upstream's own service, vendored) -------------------------------------
    pushEphemeral(slot: Fr, elements: Fr[]): number {
      const len = ephemeral.push(slot, elements);
      record('aztec_utl_pushEphemeral', 'served', `slot=${slot.toString()} len=${len}`);
      return len;
    },
    popEphemeral(slot: Fr): Fr[] {
      const value = ephemeral.pop(slot);
      record('aztec_utl_popEphemeral', 'served', `slot=${slot.toString()}`);
      return value;
    },
    getEphemeral(slot: Fr, index: number): Fr[] {
      const value = ephemeral.get(slot, index);
      record('aztec_utl_getEphemeral', 'served', `slot=${slot.toString()} index=${index}`);
      return value;
    },
    setEphemeral(slot: Fr, index: number, elements: Fr[]): void {
      ephemeral.set(slot, index, elements);
      record('aztec_utl_setEphemeral', 'served', `slot=${slot.toString()} index=${index}`);
    },
    getEphemeralLen(slot: Fr): number {
      const len = ephemeral.len(slot);
      record('aztec_utl_getEphemeralLen', 'served', `slot=${slot.toString()} len=${len}`);
      return len;
    },
    removeEphemeral(slot: Fr, index: number): void {
      ephemeral.remove(slot, index);
      record('aztec_utl_removeEphemeral', 'served', `slot=${slot.toString()} index=${index}`);
    },
    clearEphemeral(slot: Fr): void {
      ephemeral.clear(slot);
      record('aztec_utl_clearEphemeral', 'served', `slot=${slot.toString()}`);
    },

    // ---- transient arrays -------------------------------------------------------------------------
    pushTransient(slot: Fr, elements: Fr[]): number {
      const len = transient.push(contract, slot, elements);
      record('aztec_utl_pushTransient', 'served', `slot=${slot.toString()} len=${len}`);
      return len;
    },
    popTransient(slot: Fr): Fr[] {
      const value = transient.pop(contract, slot);
      record('aztec_utl_popTransient', 'served', `slot=${slot.toString()}`);
      return value;
    },
    getTransient(slot: Fr, index: number): Fr[] {
      const value = transient.get(contract, slot, index);
      record('aztec_utl_getTransient', 'served', `slot=${slot.toString()} index=${index}`);
      return value;
    },
    setTransient(slot: Fr, index: number, elements: Fr[]): void {
      transient.set(contract, slot, index, elements);
      record('aztec_utl_setTransient', 'served', `slot=${slot.toString()} index=${index}`);
    },
    getTransientLen(slot: Fr): number {
      const len = transient.len(contract, slot);
      record('aztec_utl_getTransientLen', 'served', `slot=${slot.toString()} len=${len}`);
      return len;
    },
    removeTransient(slot: Fr, index: number): void {
      transient.remove(contract, slot, index);
      record('aztec_utl_removeTransient', 'served', `slot=${slot.toString()} index=${index}`);
    },
    clearTransient(slot: Fr): void {
      transient.clear(contract, slot);
      record('aztec_utl_clearTransient', 'served', `slot=${slot.toString()}`);
    },

    // ---- execution-state sinks --------------------------------------------------------------------
    setContractSyncCacheInvalid(contractAddress: AztecAddress, scopes: { data: AztecAddress[] }): void {
      record(
        'aztec_utl_setContractSyncCacheInvalid',
        'served',
        `contract=${contractAddress.toString()} scopes=${scopes.data.length}`,
      );
    },
    emitOffchainEffect(data: Fr[]): void {
      offchainEffects.push(data.map(f => f.toString()));
      record('aztec_utl_emitOffchainEffect', 'served', `fields=${data.length}`);
    },

    // ---- the execution cache ----------------------------------------------------------------------
    setHashPreimage(values: Fr[], hash: Fr): void {
      executionCache.set(hash.toString(), [...values]);
      record('aztec_prv_setHashPreimage', 'served', `hash=${hash.toString()} len=${values.length}`);
    },
    getHashPreimage(hash: Fr): Fr[] {
      const preimage = executionCache.get(hash.toString());
      if (!preimage) {
        // A MISS IS AN ERROR AND NOT AN EMPTY ARRAY. Returning `[]` here is the exact shape this
        // milestone refuses: the circuit would carry on over values nobody stored.
        throw new Error(`aztec_prv_getHashPreimage: no preimage stored for hash ${hash.toString()}`);
      }
      record('aztec_prv_getHashPreimage', 'served', `hash=${hash.toString()} len=${preimage.length}`);
      return preimage;
    },
    assertValidPublicCalldata(calldataHash: Fr): void {
      const calldata = executionCache.get(calldataHash.toString());
      if (!calldata) {
        throw new Error(`aztec_prv_assertValidPublicCalldata: calldata for ${calldataHash.toString()} not in cache`);
      }
      // THE CAP IS UPSTREAM'S AND IS ENFORCED HERE, from `@aztec/constants` rather than typed. The
      // oracle's NAME is `assertValid…`; a handler that looked the calldata up and asserted nothing
      // about it would be a validator that validates nothing, which is this file's own first form.
      totalPublicCalldata += calldata.length;
      if (totalPublicCalldata > MAX_FR_CALLDATA_TO_ALL_ENQUEUED_CALLS) {
        throw new Error(
          `aztec_prv_assertValidPublicCalldata: too many total args to all enqueued public calls ` +
            `(${totalPublicCalldata} > ${MAX_FR_CALLDATA_TO_ALL_ENQUEUED_CALLS})`,
        );
      }
      record(
        'aztec_prv_assertValidPublicCalldata',
        'served',
        `fields=${calldata.length} total=${totalPublicCalldata}`,
      );
    },

    // ---- the notify* family -------------------------------------------------------------------------
    notifyCreatedNote(
      owner: AztecAddress,
      storageSlot: Fr,
      _randomness: Fr,
      _noteTypeId: unknown,
      _note: Fr[],
      noteHash: Fr,
      counter: number,
    ): void {
      createdNotes.push({
        owner: owner.toString(),
        storageSlot: storageSlot.toString(),
        noteHash: noteHash.toString(),
        counter,
      });
      // The PENDING list is what `notifyNullifiedNote` consumes from, so a note nullified in the same
      // execution has to have been created in it. Kept beside the report rather than derived from it,
      // because the report is append-only by design and this one loses entries.
      pendingNotes.push({ noteHash, counter });
      record('aztec_prv_notifyCreatedNote', 'served', `noteHash=${noteHash.toString()} counter=${counter}`);
    },
    async notifyNullifiedNote(innerNullifier: Fr, noteHash: Fr, counter: number): Promise<void> {
      // UPSTREAM'S TWO BRANCHES, BOTH OF THEM. A non-empty note hash means a note created EARLIER IN
      // THIS EXECUTION is being consumed, and upstream refuses one that is not there —
      // `Attempt to remove a pending note that does not exist.` An empty note hash means the note
      // came from a previous transaction, and then the nullifier IS emitted. A handler that only
      // recorded would accept the consumption of a note nobody created, which is the fabricated-note
      // shape arriving from the other direction.
      const siloed = await siloNullifier(contract, innerNullifier);
      if (!noteHash.isZero()) {
        const index = pendingNotes.findIndex(n => n.noteHash.equals(noteHash));
        if (index === -1) {
          throw new Error(
            `aztec_prv_notifyNullifiedNote: attempt to remove a pending note that does not exist ` +
              `(noteHash ${noteHash.toString()})`,
          );
        }
        const [note] = pendingNotes.splice(index, 1);
        // A note created BEFORE the revertible phase and nullified INSIDE it emits both.
        if (inRevertiblePhase && note.counter < minRevertibleSideEffectCounter) {
          recordNullifier(siloed, 'aztec_prv_notifyNullifiedNote');
        }
      } else {
        recordNullifier(siloed, 'aztec_prv_notifyNullifiedNote');
      }
      nullifiedNotes.push({
        innerNullifier: innerNullifier.toString(),
        noteHash: noteHash.toString(),
        counter,
      });
      record('aztec_prv_notifyNullifiedNote', 'served', `noteHash=${noteHash.toString()} counter=${counter}`);
    },
    async notifyCreatedNullifier(innerNullifier: Fr): Promise<void> {
      // A DUPLICATE IS AN ERROR AND NOT A SECOND ENTRY IN A SET. Upstream's `#recordNullifier`
      // throws `Duplicate siloed nullifier … emitted by contract …`, and a handler that accepted one
      // silently would wave a double-spend WITHIN ONE TRANSACTION through the one layer that can see
      // it. `Set.add` on an existing member is a no-op, so the permissive version is not even
      // visibly wrong afterwards — which is why this is a `throw` and not a log line.
      recordNullifier(await siloNullifier(contract, innerNullifier), 'aztec_prv_notifyCreatedNullifier');
      createdNullifiers.push(innerNullifier.toString());
      record('aztec_prv_notifyCreatedNullifier', 'served', `inner=${innerNullifier.toString()}`);
    },
    notifyCreatedContractClassLog(
      contractAddress: AztecAddress,
      _message: Fr[],
      length: number,
      counter: number,
    ): void {
      contractClassLogs.push({ contractAddress: contractAddress.toString(), emittedLength: length, counter });
      record('aztec_prv_notifyCreatedContractClassLog', 'served', `length=${length} counter=${counter}`);
    },
    notifyRevertiblePhaseStart(minCounter: number): void {
      if (inRevertiblePhase) {
        throw new Error(
          `aztec_prv_notifyRevertiblePhaseStart: cannot enter the revertible phase twice ` +
            `(previous counter ${minRevertibleSideEffectCounter}, new ${minCounter})`,
        );
      }
      inRevertiblePhase = true;
      minRevertibleSideEffectCounter = minCounter;
      record('aztec_prv_notifyRevertiblePhaseStart', 'served', `min=${minCounter}`);
    },
    async isNullifierPending(innerNullifier: Fr, contractAddress: AztecAddress): Promise<boolean> {
      const siloed = await siloNullifier(contractAddress, innerNullifier);
      const pending = pendingNullifiers.has(siloed.toString());
      record('aztec_prv_isNullifierPending', 'served', `inner=${innerNullifier.toString()} pending=${pending}`);
      return pending;
    },
    isExecutionInRevertiblePhase(sideEffectCounter: number): boolean {
      const revertible = inRevertiblePhase && sideEffectCounter >= minRevertibleSideEffectCounter;
      record(
        'aztec_prv_isExecutionInRevertiblePhase',
        'served',
        `counter=${sideEffectCounter} revertible=${revertible}`,
      );
      return revertible;
    },
  };

  // THE ONE NON-ORACLE METHOD THE VENDORED CALLBACK READS, AND LEAVING IT OUT PRODUCED A
  // MISLEADING MESSAGE RATHER THAN A MISSING ONE.
  //
  // `makeUnknownOracleTrap` fires when the BYTECODE calls an oracle name the registry does not
  // declare — which is the other half of the milestone's "a bytecode/oracle mismatch is loud"
  // deliverable, the half `assertCompatibleOracleVersion` cannot cover. Its diagnostic has three
  // branches and it picks between them with `'nonOracleFunctionGetContractOracleVersion' in handler`.
  // Without this method it takes the FIRST branch and says *"the contract's oracle version is
  // unknown (the version check oracle was not called before …). This usually means the contract was
  // not compiled with the #[aztec] macro"* — over a contract that called the version oracle first,
  // as every `#[aztec]` contract does, and whose version this handler has been holding since. A
  // wrong explanation is worse than none, and it is worse in exactly this campaign's way: it names
  // a cause the reader will go and check.
  //
  // Upstream prefixes it `nonOracleFunction` for the same reason it is excluded from the surface
  // reconciliation below: it is not in `ORACLE_REGISTRY` and `buildACIRCallback` never dispatches to
  // it.
  const NON_ORACLE_METHODS = ['nonOracleFunctionGetContractOracleVersion'];

  // Every refused oracle gets a thunk that names itself. Built from the DERIVED refusing set, so a
  // sixty-ninth upstream oracle arrives here rather than falling through to `undefined` — which
  // would make `buildACIRCallback` call `undefined(...)` and produce a TypeError naming nothing.
  const handler: Record<string, unknown> = { isMisc: true, isUtility: true, isPrivate: true };
  for (const [method, fn] of Object.entries(served)) {
    handler[method] = fn;
  }
  for (const oracle of ORACLE_REFUSING) {
    const method = oracleMethodName(oracle);
    const reason = ORACLE_REFUSAL_REASONS[oracle] ?? 'no reason declared, which is itself a defect';
    handler[method] = () => {
      record(oracle, 'refused', reason);
      throw new OracleUnimplemented(oracle, reason);
    };
  }

  // THE HOOK IS ATTACHED AFTER `handler` EXISTS, and the first version of this was three lines
  // higher — before the `const handler` declaration — which is a temporal dead zone, and the page
  // reported it as `ReferenceError: Cannot access 'G' before initialization` inside a minified chunk
  // with a stack that named `armPrivateExecution` and nothing else. Three rounds of bisecting the
  // MODULE graph went by before the real cause turned out to be five lines of local ordering.
  handler.nonOracleFunctionGetContractOracleVersion = () => contractVersion;

  assertOracleSurfaceMatchesDeclaration(
    Object.keys(handler).filter(
      k => !['isMisc', 'isUtility', 'isPrivate', ...NON_ORACLE_METHODS].includes(k),
    ),
  );

  return {
    handler,
    calls: () => calls,
    contractVersion: () => contractVersion,
    effects: () => ({
      createdNotes,
      createdNullifiers,
      nullifiedNotes,
      contractClassLogs,
      offchainEffects,
      randomFields: randomCounter,
    }),
  };
}
