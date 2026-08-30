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
import { MAX_FR_CALLDATA_TO_ALL_ENQUEUED_CALLS, PRIVATE_LOG_CIPHERTEXT_LEN } from '@aztec/constants';
import { siloNullifier } from '@aztec/stdlib/hash';
import { poseidon2HashWithSeparator } from '@aztec/foundation/crypto/poseidon';
// The address derivation is UPSTREAM'S OWN, not a re-implementation. `computeContractAddressFromInstance`
// is the TypeScript side of the same computation `ContractInstance::to_address()` performs inside the
// circuit, so the guard below and `aztec-nr`'s `assert_eq` are two evaluations of one function rather
// than two functions that ought to agree. Re-implementing it here would have produced a guard that
// passes exactly when it is wrong in the same way the handler is.
import { computeContractAddressFromInstance } from '@aztec/stdlib/contract';
// `computeAddress` is the TypeScript half of the circuit's `AztecAddress::compute(public_keys,
// partial_address)`, and it is the SAME function `dev_keys.ts` already derives its accounts with
// (RI-96) — so the wallet's derivation, this guard and `aztec-nr`'s assertion are three uses of one
// computation rather than three that ought to agree.
import { computeAddress, type PublicKeys } from '@aztec/stdlib/keys';
import { AppTaggingSecret, type AppTaggingSecretKind, SiloedTag } from '@aztec/stdlib/logs';
import { TxHash } from '@aztec/stdlib/tx';

import { ORACLE_REGISTRY } from '../vendor/pxe/contract_function_simulator/oracle/oracle_registry.ts';
import { ORACLE_VERSION_MAJOR, ORACLE_VERSION_MINOR } from '../vendor/pxe/oracle_version.ts';
import { Option } from '../vendor/pxe/contract_function_simulator/noir-structs/option.ts';
import { EphemeralArrayService } from '../vendor/pxe/contract_function_simulator/ephemeral_array_service.ts';
import { EphemeralArray } from '../vendor/pxe/contract_function_simulator/noir-structs/ephemeral_array.ts';
import { BoundedVec } from '../vendor/pxe/contract_function_simulator/noir-structs/bounded_vec.ts';
import { TransientArrayService } from '../vendor/pxe/contract_function_simulator/transient_array_service.ts';
import type { NoteValidationRequest } from '../vendor/pxe/contract_function_simulator/noir-structs/note_validation_request.ts';
import type { LogRetrievalRequest } from '../vendor/pxe/contract_function_simulator/noir-structs/log_retrieval_request.ts';
import type { LogRetrievalResponse } from '../vendor/pxe/contract_function_simulator/noir-structs/log_retrieval_response.ts';
import type { PendingTaggedLog } from '../vendor/pxe/contract_function_simulator/noir-structs/pending_tagged_log.ts';
import type { ProvidedSecret } from '../vendor/pxe/contract_function_simulator/noir-structs/provided_secret.ts';
import type { ResolvedTx } from '../vendor/pxe/contract_function_simulator/noir-structs/resolved_tx.ts';
import type { DevNoteDatabase, RetrievedTaggedLog } from './note_database.ts';
import type { DevTagging, DeterministicEphemeralArrayService } from './dev_tagging.ts';

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
    // tier 2's SECOND rung — the account key directory (RI-96). Its absence encoding is upstream's
    // `Option::none()` rather than a throw, and the reason is in the handler body: unlike rung 1,
    // this oracle's declared return is an `Option`, so "not registered" HAS a home in the type.
    'aztec_utl_getPublicKeysAndPartialAddress',
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

/**
 * M36 — the nine oracles a handler serves ONLY when a note-discovery source is attached.
 *
 * ===========================================================================================
 * WHY THIS IS A SECOND PARTITION AND NOT NINE MORE ENTRIES IN THE FIRST
 * ===========================================================================================
 *
 * M35 established that *"implemented" means "observed to answer"* — the served set and the set the
 * arm actually reached are asserted equal in both directions. These nine cannot answer without a
 * note database, a tagging half and a contract-instance source, and a handler built without them
 * would carry nine methods that are declared served and refuse. **That is exactly the
 * plausible-default shape wearing a table of contents** — M34's `DEV_WALLET_SERVED` finding.
 *
 * So the surface is a FUNCTION of what the handler was given, and both partitions are checked: each
 * is disjoint from its complement, each sums to the re-derived registry count, and
 * `assertOracleSurfaceMatchesDeclaration` reconciles the one that applies at construction.
 *
 * `aztec_utl_getContractInstance` is NOT in this set, and it was until the two tier-2 answers met.
 * M36 reached that rung independently and put the oracle here, served only with a discovery source
 * and recording `refused` for an address the wallet does not hold. The always-served directory above
 * is the better model — an unheld address is a fact about the DATA and `unavailable` is what says so
 * — so this set is the EIGHT note and tagging oracles and nothing else. `LOCAL-HISTORY.md` §2 keeps
 * the measurement that decided the rung, because it is the same measurement either way.
 */
export const ORACLE_DISCOVERY: readonly string[] = Object.freeze(
  [
    // note discovery
    'aztec_utl_getNotes',
    'aztec_utl_getPendingTaggedLogsV2',
    'aztec_utl_getLogsByTagV2',
    'aztec_utl_validateAndStoreEnqueuedNotesAndEvents',
    // tagging
    'aztec_prv_getAppTaggingSecret',
    'aztec_prv_getNextTaggingIndex',
    'aztec_prv_getSenderForTags',
    'aztec_prv_resolveTaggingStrategy',
  ].sort(),
);

/** The served set when a discovery source IS attached. Derived from the two lists above. */
export const ORACLE_IMPLEMENTED_WITH_DISCOVERY: readonly string[] = Object.freeze(
  [...ORACLE_IMPLEMENTED, ...ORACLE_DISCOVERY].sort(),
);

/** Everything else, DERIVED. A new upstream oracle lands here without an edit. */
export const ORACLE_REFUSING: readonly string[] = Object.freeze(
  ORACLE_NAMES.filter(n => !ORACLE_IMPLEMENTED.includes(n)),
);

/** Everything else when a discovery source is attached, DERIVED on the same terms. */
export const ORACLE_REFUSING_WITH_DISCOVERY: readonly string[] = Object.freeze(
  ORACLE_NAMES.filter(n => !ORACLE_IMPLEMENTED_WITH_DISCOVERY.includes(n)),
);

/**
 * Why each refused oracle is refused, and what would have to exist for it to stop refusing.
 *
 * A refusal that says only "not implemented" is a refusal a reader cannot act on, so each reason
 * names the TIER (the milestone's own four: in-memory, adapters, crypto, `callPrivateFunction`) and
 * the milestone that owns it. Four of these reasons are MEASUREMENTS rather than plans — see
 * `EPHEMERAL_RETURN_ORACLES` below.
 */
const NO_DISCOVERY_SOURCE = (needs: string) =>
  `M36 serves this oracle, and this handler was built WITHOUT a discovery source, so it has no ` +
  `${needs}. Pass \`discovery\` to createPrivateOracleHandler — a note database fed by the dev ` +
  `node's own block stream, the wallet's tagging half, and the wallet's registered contract ` +
  `instances. See LOCAL-HISTORY.md for what that history is and is not.`;

export const ORACLE_REFUSAL_REASONS: Readonly<Record<string, string>> = Object.freeze({
  // ---- tier 2, the adapters over exports this runtime already has -----------------------------
  // `aztec_utl_getContractInstance` WAS HERE and is now served — tier 2's first rung. It is the
  // one refusal this campaign removed by building the thing rather than by lowering the bar, and
  // what replaced it is not "always answer": an address the wallet does not hold still refuses, by
  // name, through `ContractInstanceNotHeld`. See section 3a of PRIVATE-EXECUTION.md.
  //
  // M36 KEEPS THAT MODEL RATHER THAN ITS OWN, and the reason is worth the sentence: M36 reached the
  // same rung independently and put the oracle in a SECOND partition, served only when a
  // note-discovery source is attached, recording `refused` for an address the wallet does not hold.
  // That records a fact about the DATA as a fact about the PARTITION — the very confusion the
  // `unavailable` outcome below exists to prevent — and the always-served directory is the better
  // model. M36's second partition is therefore the EIGHT note and tagging oracles and nothing else.
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
  // `aztec_utl_getPublicKeysAndPartialAddress` WAS HERE and is now served — tier 2's second rung,
  // over the same RI-96 derivation the wallet already had. See section 3b of PRIVATE-EXECUTION.md,
  // and read its constraint note: this oracle's answer is constrained on ONE of its two consumer
  // paths and not on the other.
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
    'property forbids. See PRIVATE-EXECUTION.md section 5. **M36 ANSWERED THAT MEASUREMENT** with ' +
    'DeterministicEphemeralArrayService (LOCAL-HISTORY.md section 5), so this is no longer a ' +
    'blocker and is now simply unbuilt — the fact store itself is what is missing, not a reason it ' +
    'cannot exist. Recorded rather than rewritten, because a refusal whose stated cause has been ' +
    'removed is a refusal a reader will act on wrongly',
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
  // ---- M36, served ONLY when a discovery source is attached -------------------------------------
  //
  // These eight are M36's, and the reason each gives when it refuses is the reason it CANNOT answer
  // rather than a milestone number: a handler built with no note database has nowhere to look, and
  // saying "M36" to a reader who is running M36's own code would name a cause they would go and
  // check — `CAMPAIGN-BRIEF.md`'s "a wrong explanation is worse than none".
  aztec_utl_getNotes: NO_DISCOVERY_SOURCE('note discovery: the note table these are read from'),
  aztec_utl_getPendingTaggedLogsV2: NO_DISCOVERY_SOURCE('note discovery: the tag index and the wallet\'s own tagging secrets'),
  aztec_utl_getLogsByTagV2: NO_DISCOVERY_SOURCE('note discovery: the tag index'),
  aztec_utl_validateAndStoreEnqueuedNotesAndEvents:
    NO_DISCOVERY_SOURCE('note discovery: the note table a validated note is stored in, and the block history it is validated against'),
  aztec_prv_getAppTaggingSecret: NO_DISCOVERY_SOURCE('tagging: the wallet\'s own account keys'),
  aztec_prv_getNextTaggingIndex: NO_DISCOVERY_SOURCE('tagging: the per-secret index counter'),
  aztec_prv_getSenderForTags: NO_DISCOVERY_SOURCE('tagging: the wallet\'s default sender'),
  aztec_prv_resolveTaggingStrategy: NO_DISCOVERY_SOURCE('tagging: the wallet\'s own account keys'),
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
  /**
   * The accounts whose public keys this wallet holds, for
   * `aztec_utl_getPublicKeysAndPartialAddress` — tier 2's second rung.
   *
   * Same boundary as the directory above, and the same default: omitted means the wallet holds
   * nothing, and every address answers "not registered". `deriveDevAccounts` (RI-96) already
   * produces exactly this triple for the wallet's own accounts, so this is the wallet publishing
   * what it derives rather than a new source of keys.
   */
  readonly accountKeys?: readonly HeldAccountKeys[];
}

/**
 * One account whose keys the wallet holds: an address, upstream's `PublicKeys`, and the partial
 * address that together with them DERIVES that address.
 *
 * **THE ADDRESS IS A FUNCTION OF THE OTHER TWO, AND THE CIRCUIT CHECKS IT — ON ONE PATH.**
 * `aztec-nr`'s `get_public_keys` is:
 *
 * ```
 * let (public_keys, partial_address) = unsafe { get_public_keys_and_partial_address(account) };
 * assert_eq(account, AztecAddress::compute(public_keys, partial_address),
 *           "Invalid public keys hint for address");
 * ```
 *
 * — the same shape as rung 1, and upstream ships its own test (`get_public_keys_fails_with_bad_hint`)
 * proving a fabricated answer fails there.
 *
 * **BUT `try_get_public_keys` DOES NOT CHECK IT**, and that is recorded here rather than left to be
 * discovered: it is `unconstrained`, it DISCARDS the partial address, and it performs no assertion —
 * so on that path a wrong answer is not caught by the circuit. `PRIVATE-EXECUTION.md` §3b states
 * what that means for this wallet. `assertHeldAccountKeysAreSelfConsistent` therefore is not merely
 * a better error message the way rung 1's guard is; on the unconstrained path it is the ONLY thing
 * checking the relation.
 */
export interface HeldAccountKeys {
  /** The account address, which must equal what the two fields below derive to. */
  readonly address: AztecAddress;
  readonly publicKeys: PublicKeys;
  readonly partialAddress: Fr;
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
  /**
   * M36's note-discovery source. **Absent by default, and its absence is a set of named refusals
   * rather than a set of empty answers.**
   */
  readonly discovery?: NoteDiscoverySource;
}

/**
 * Everything the eight discovery oracles need, supplied by the caller.
 *
 * The contract-instance directory is NOT here: `aztec_utl_getContractInstance` is served
 * unconditionally from `PrivateOracleOptions.contractInstances`, which is the model the two
 * independent tier-2 answers settled on.
 *
 * IT IS AN INTERFACE AND NOT AN IMPORT, for the reason `DevWalletHost` is: `wallet.js` is a separate
 * entry point so that a page attaching no wallet pays for none of it, and a handler that imported
 * the chain would drag the runtime in from the other side.
 */
export interface NoteDiscoverySource {
  /** The note table, the tag index and the nullifier set, fed by the dev node's own block stream. */
  readonly noteDb: DevNoteDatabase;
  /** The wallet's tagging half — accounts, secrets, index counters. */
  readonly tagging: DevTagging;
  /**
   * The ephemeral-array service. It is the DETERMINISTIC one, which is what answers
   * `PRIVATE-EXECUTION.md` §5's measurement rather than inheriting it, and it is supplied here
   * rather than constructed inside so that the two return-carrying oracles and the seven
   * `*Ephemeral` bookkeeping oracles share ONE service — as upstream's do.
   */
  readonly ephemeral: DeterministicEphemeralArrayService;
  /** The block this execution is anchored to. A note from a newer block is refused. */
  readonly anchorBlockNumber: number;
  /**
   * The ACCOUNT scopes this execution may act for — upstream's own `this.scopes`.
   *
   * IT IS THE SUBJECT OF THREE OF UPSTREAM'S OWN GUARDS AND NOT A FILTER PARAMETER. `fetchTaggedLogs`,
   * `getAppTaggingSecret` and `NoteService.getNotes` all consult it, the first two through
   * `assertAllowedScope`, which THROWS naming the scope and the list. A handler without it lets a
   * contract ask for another account's tagged logs and for another account's tagging secret — and
   * neither is visibly wrong afterwards, because the answer is well-formed either way.
   *
   * REQUIRED AND NON-EMPTY. An empty list would make `assertAllowedScope` refuse everything, which
   * reads as "the wallet holds nothing" rather than as a caller who forgot an argument.
   */
  readonly scopes: readonly AztecAddress[];
  /**
   * How many tagging indexes past the last used one `getPendingTaggedLogsV2` probes.
   *
   * A WINDOW AND NOT AN UNBOUNDED SCAN, and the number is the caller's rather than a constant here,
   * because it is a statement about how far ahead a sender may have run — which is a property of the
   * deployment and not of the handler.
   */
  readonly taggingProbeWindow?: number;
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
    createdNotes: readonly {
      owner: string;
      storageSlot: string;
      noteHash: string;
      counter: number;
      /** The note's randomness, which a validation request carries and the note hash commits to. */
      randomness: string;
      /** The note's packed content, which is what `getNotes` hands back and `pickNotes` selects on. */
      content: readonly string[];
    }[];
    createdNullifiers: readonly string[];
    nullifiedNotes: readonly { innerNullifier: string; noteHash: string; counter: number }[];
    contractClassLogs: readonly { contractAddress: string; emittedLength: number; counter: number }[];
    offchainEffects: readonly string[][];
    randomFields: number;
  };
  /** Whether a discovery source was attached, so a report says which partition was in force. */
  hasDiscovery(): boolean;
  /** The served set that was actually in force, as a set a check can compare. */
  servedSet(): readonly string[];
}

/**
 * Reconciles the declared partition against the object that actually answers, in both directions,
 * and throws naming the difference. Exported so a check can exercise it over the BUILT bundle with
 * a doctored list and see it fire — a guard nobody has seen refuse is a guard nobody has tested.
 */
export function assertOracleSurfaceMatchesDeclaration(
  methodNames: readonly string[],
  withDiscovery = false,
): void {
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
  // BOTH PARTITIONS ARE CHECKED, NOT ONLY THE ONE IN FORCE. A handler built without a discovery
  // source would otherwise never exercise the with-discovery partition's arithmetic, and a
  // ninth-oracle typo in `ORACLE_DISCOVERY` would sit undetected until a page happened to attach a
  // note database.
  for (const [label, implemented, refusing] of [
    ['without discovery', ORACLE_IMPLEMENTED, ORACLE_REFUSING],
    ['with discovery', ORACLE_IMPLEMENTED_WITH_DISCOVERY, ORACLE_REFUSING_WITH_DISCOVERY],
  ] as const) {
    const overlap = implemented.filter(n => refusing.includes(n));
    if (overlap.length > 0) {
      throw new Error(`the implemented and refusing sets are not disjoint ${label}: [${overlap.join(', ')}]`);
    }
    if (implemented.length + refusing.length !== ORACLE_NAMES.length) {
      throw new Error(
        `the implemented and refusing sets do not sum to the registry ${label}: ` +
          `${implemented.length} + ${refusing.length} !== ${ORACLE_NAMES.length}`,
      );
    }
  }
  // AND EVERY DISCOVERY ORACLE MUST BE A REGISTRY ORACLE. `ORACLE_DISCOVERY` is a typed list, so it
  // is the one place in this file a name could be invented; `ORACLE_REFUSING_WITH_DISCOVERY` would
  // silently absorb a misspelling as "one more refusal" and the sums above would still hold.
  const invented = ORACLE_DISCOVERY.filter(n => !ORACLE_NAMES.includes(n));
  if (invented.length > 0) {
    throw new Error(`ORACLE_DISCOVERY names oracles the registry does not declare: [${invented.join(', ')}]`);
  }
  const inBoth = ORACLE_DISCOVERY.filter(n => ORACLE_IMPLEMENTED.includes(n));
  if (inBoth.length > 0) {
    throw new Error(`ORACLE_DISCOVERY overlaps the always-served set: [${inBoth.join(', ')}]`);
  }
  // The reasons are checked against the partition IN FORCE, because a discovery oracle that is
  // served needs no reason and one that is refused does.
  const refusingNow = withDiscovery ? ORACLE_REFUSING_WITH_DISCOVERY : ORACLE_REFUSING;
  const unexplained = refusingNow.filter(n => !ORACLE_REFUSAL_REASONS[n]);
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

/**
 * Re-derives every held account's address from its own public keys and partial address, and throws
 * naming any that disagrees.
 *
 * **THIS ONE IS LOAD-BEARING IN A WAY RUNG 1'S IS NOT, AND THE DIFFERENCE IS UPSTREAM'S.** Rung 1's
 * guard is a better error message for something the circuit would have caught anyway. Here the
 * circuit catches it on `get_public_keys` and NOT on `try_get_public_keys`, which is `unconstrained`,
 * discards the partial address and asserts nothing. So for that consumer this function is the only
 * check that the triple is coherent, and it runs before the frame starts rather than never.
 */
export async function assertHeldAccountKeysAreSelfConsistent(
  accounts: readonly HeldAccountKeys[],
): Promise<void> {
  const seen = new Set<string>();
  for (const [i, held] of accounts.entries()) {
    const key = held.address.toString();
    if (seen.has(key)) {
      throw new Error(
        `the account key directory holds two entries for ${key}; an address is a key and a second ` +
          `entry for it would silently shadow the first`,
      );
    }
    seen.add(key);
    const derived = await computeAddress(held.publicKeys, held.partialAddress);
    if (!derived.equals(held.address)) {
      throw new Error(
        `account key directory entry ${i} is not self-consistent: it is filed under ${key} but its ` +
          `own public keys and partial address derive to ${derived.toString()}. aztec-nr's ` +
          `get_public_keys asserts exactly this equality — but try_get_public_keys does NOT, so on ` +
          `that path nothing downstream would have caught it.`,
      );
    }
  }
}

/**
 * Upstream's `assertAllowedScope`, which THREE of its own handlers call and this one was missing.
 *
 * `pxe/src/storage/allowed_scopes.ts` is fourteen lines and it is not vendored, because vendoring a
 * fourteen-line file to get a `some(...)` would be provenance machinery around a predicate. What IS
 * taken from upstream is the RULE and the shape of the refusal: it names the scope AND the list, so
 * a reader can see which account was asked for and which the execution holds.
 */
export function assertAllowedScope(
  scope: AztecAddress,
  allowedScopes: readonly AztecAddress[],
  oracle: string,
): void {
  if (allowedScopes.length === 0) {
    throw new Error(
      `${oracle}: this execution was given an EMPTY scope list, so every scope is out of scope. That ` +
        'is a caller who omitted an argument rather than a wallet that holds nothing, and the two ' +
        'produce the same answer, so it is refused here.',
    );
  }
  if (!allowedScopes.some(allowed => allowed.equals(scope))) {
    throw new Error(
      `${oracle}: scope ${scope.toString()} is not in this execution's allowed scopes ` +
        `[${allowedScopes.map(s => s.toString()).join(', ')}]. A contract may not read another ` +
        'account\'s tagged logs or derive another account\'s tagging secret.',
    );
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
  // The account key directory, same construction and same fixed-for-the-frame property.
  const accountDirectory = new Map<string, HeldAccountKeys>(
    (options.accountKeys ?? []).map(a => [a.address.toString(), a]),
  );
  const discovery = options.discovery;
  const capsules = new Map<string, Fr[]>();
  // ONE SERVICE PER FRAME, AND IT IS THE CALLER'S WHEN THERE IS ONE. `EphemeralArray.fromSlot`
  // resolves a slot against whatever service `readAll` is given, so a handler that used a second
  // service for its returns would hand back slots the bookkeeping oracles cannot see.
  const ephemeral: EphemeralArrayService = discovery?.ephemeral ?? new EphemeralArrayService();
  const transient = new TransientArrayService();
  const executionCache = new Map<string, Fr[]>();
  const pendingNullifiers = new Set<string>();
  const pendingNotes: { noteHash: Fr; counter: number }[] = [];
  let totalPublicCalldata = 0;
  const createdNotes: {
    owner: string;
    storageSlot: string;
    noteHash: string;
    counter: number;
    randomness: string;
    content: string[];
  }[] = [];
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

    // ---- tier 2, rung 2: the account key directory (RI-96) --------------------------------------
    //
    // ABSENCE IS RETURNED HERE, NOT THROWN, AND THAT IS NOT A WEAKENING OF RUNG 1'S RULE — IT IS
    // THE SAME RULE READ OFF A DIFFERENT RETURN TYPE.
    //
    // Rung 1's `getContractInstance` declares a BARE `CONTRACT_INSTANCE`, so "I do not know" has
    // nowhere to go in the type and must be a throw. This oracle declares
    // `OPTION(PUBLIC_KEYS_AND_PARTIAL_ADDRESS)`: the protocol itself defines an encoding for "not
    // registered", and upstream's own `get_public_keys_and_partial_address` turns it into a NAMED
    // failure — `.expect(f"Public keys not registered for account {address}")`. Throwing instead
    // would be substituting our refusal for the protocol's, and it would BREAK
    // `try_get_public_keys`, whose entire purpose is to ask the question and accept `None` as an
    // answer. A contract asking "does this account have registered keys?" must get `false`, not an
    // aborted frame.
    //
    // So the miss is recorded as SERVED with `present=false` — the same shape `getCapsule` uses for
    // a miss — and it is visible in the ledger either way, which is what DEV-WALLET.md §1's first
    // design property actually asks for. It is NOT an `unavailable`: that outcome means "served
    // oracle, no answer possible, the frame halts here", and this frame does not halt.
    getPublicKeysAndPartialAddress(address: AztecAddress): Option<{
      publicKeys: PublicKeys;
      partialAddress: Fr;
    }> {
      const held = accountDirectory.get(address.toString());
      record(
        'aztec_utl_getPublicKeysAndPartialAddress',
        'served',
        `address=${address.toString()} registered=${held !== undefined}`,
      );
      return held
        ? Option.some({ publicKeys: held.publicKeys, partialAddress: held.partialAddress })
        : Option.none();
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

    // ---- execution-state sinks, HONOURED RATHER THAN STUBBED (M36's fourth deliverable) ----------
    //
    // M35 served both of these and both of them were sinks: `setContractSyncCacheInvalid` recorded a
    // line and invalidated nothing, because there was no sync cache to invalidate, and
    // `emitOffchainEffect` pushed into an array nobody read. That was the honest thing to do with no
    // note database attached, and it is not the same as HONOURING them. With one attached, the
    // invalidation reaches the cache the note oracles consult and the effect is DELIVERED — and the
    // ledger detail says which of the two happened, so "honoured" is a fact a check reads rather
    // than a word in a document.
    setContractSyncCacheInvalid(contractAddress: AztecAddress, scopes: { data: AztecAddress[] }): void {
      const delivered = discovery
        ? discovery.noteDb.invalidateSyncCache(contractAddress, scopes.data)
        : undefined;
      record(
        'aztec_utl_setContractSyncCacheInvalid',
        'served',
        `contract=${contractAddress.toString()} scopes=${scopes.data.length} ` +
          (delivered === undefined ? 'honoured=no (no discovery source)' : `honoured=yes invalidated=${delivered}`),
      );
    },
    emitOffchainEffect(data: Fr[]): void {
      offchainEffects.push(data.map(f => f.toString()));
      const delivered = discovery ? discovery.noteDb.deliverOffchainEffect(contract, data) : undefined;
      record(
        'aztec_utl_emitOffchainEffect',
        'served',
        `fields=${data.length} ` +
          (delivered === undefined ? 'honoured=no (no discovery source)' : `honoured=yes delivered=${delivered}`),
      );
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
      randomness: Fr,
      _noteTypeId: unknown,
      note: Fr[],
      noteHash: Fr,
      counter: number,
    ): void {
      // M36 KEEPS THE RANDOMNESS AND THE CONTENT, and M35 kept neither. They are not decoration: a
      // `NoteValidationRequest` carries both, `pickNotes` selects on the content, and the note hash
      // commits to the randomness — so a note database fed from a record that dropped them could
      // store a note it could never validate and could never query.
      createdNotes.push({
        owner: owner.toString(),
        storageSlot: storageSlot.toString(),
        noteHash: noteHash.toString(),
        counter,
        randomness: randomness.toString(),
        content: note.map(f => f.toString()),
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

  // ===========================================================================================
  // M36 — THE NINE, SERVED ONLY WHEN A DISCOVERY SOURCE IS ATTACHED
  // ===========================================================================================
  //
  // Every one of them answers from `LOCAL-HISTORY.md`'s subject: the dev node's OWN block stream.
  // None of them fetches, and a query that reaches past what this node produced is `LocalHistoryOnly`
  // — refused by name rather than answered with the prefix that happens to exist.

  /** Turns one of this database's retrieved logs into the on-chain context the wire hands back. */
  const toResolvedTx = (log: RetrievedTaggedLog): ResolvedTx => ({
    txHash: TxHash.fromString(log.txHash),
    uniqueNoteHashesInTx: [...log.noteHashes],
    // UPSTREAM'S OWN CHOICE OF FIELD AND ITS OWN HAZARD. `firstNullifierInTx` is `nullifiers[0]`,
    // and a transaction with no nullifiers has none — upstream reads it unguarded. Here that is a
    // named error rather than `undefined` travelling into the codec, because a zero field would be
    // a nonce seed the note-hash derivation then uses.
    firstNullifierInTx: (() => {
      const first = log.nullifiers[0];
      if (first === undefined) {
        throw new Error(
          `aztec_utl_getPendingTaggedLogsV2: transaction ${log.txHash} emitted no nullifiers, so it has ` +
            'no first nullifier for note-nonce derivation. Every Aztec transaction emits at least one ' +
            '(its own hash), so this is a fact about how the block was sealed rather than about the log.',
        );
      }
      return first;
    })(),
    blockNumber: log.blockNumber as never,
    blockHash: log.blockHash,
  });

  const discoveryServed: Record<string, (...args: never[]) => unknown> = discovery
    ? {
        // ---- note discovery -----------------------------------------------------------------------
        getNotes(
          owner: Option<AztecAddress>,
          storageSlot: Fr,
          numSelects: number,
          selectByIndexes: number[],
          selectByOffsets: number[],
          selectByLengths: number[],
          selectValues: Fr[],
          selectComparators: number[],
          sortByIndexes: number[],
          sortByOffsets: number[],
          sortByLengths: number[],
          sortOrder: number[],
          limit: number,
          offset: number,
          status: number,
          maxNotes: number,
          packedHintedNoteLength: number,
        ): unknown {
          // THE QUERY IS ASSEMBLED EXACTLY AS UPSTREAM'S HANDLER ASSEMBLES IT, including
          // `selectByIndexes.slice(0, numSelects)` — the twelve query parameters are FIXED-WIDTH
          // arrays on the wire and `numSelects` is how many of them are real. Reading all of them
          // would filter on zero-valued selectors nobody asked for.
          const picked = discovery.noteDb.getNotes({
            contractAddress: contract,
            owner: owner.value,
            storageSlot,
            status,
            // THE EXECUTION'S OWN SCOPES, WHICH ARE REQUIRED AND NON-EMPTY. Upstream's
            // `NoteStore.getNotes` intersects a note's scope with this set and returns [] for an
            // empty one — correct for a caller that meant "no scopes", and a silent empty result
            // for one that meant "the default". Measured: with `scopes: []` this oracle returned
            // ZERO notes over a note that WAS stored, and every other figure was right.
            scopes: discovery.scopes,
            selects: selectByIndexes.slice(0, numSelects).map((index, i) => ({
              selector: { index, offset: selectByOffsets[i]!, length: selectByLengths[i]! },
              value: selectValues[i]!,
              comparator: selectComparators[i]!,
            })),
            sorts: sortByIndexes.map((index, i) => ({
              selector: { index, offset: sortByOffsets[i]!, length: sortByLengths[i]! },
              order: sortOrder[i]!,
            })),
            limit,
            offset,
          });
          record(
            'aztec_utl_getNotes',
            'served',
            `slot=${storageSlot.toString()} status=${status} selects=${numSelects} notes=${picked.length}`,
          );
          return BoundedVec.from({ data: picked, maxLength: maxNotes, elementSize: packedHintedNoteLength });
        },

        async getPendingTaggedLogsV2(
          scope: AztecAddress,
          providedSecrets: EphemeralArray<ProvidedSecret>,
        ): Promise<EphemeralArray<PendingTaggedLog>> {
          // TWO SOURCES OF SECRET, AND UPSTREAM HAS BOTH. The contract may PROVIDE secrets (a
          // handshake it already did), and the wallet DERIVES the ones it can from its own keys. A
          // handler that read only the provided ones would find nothing for an ordinary send.
          // UPSTREAM'S `assertAllowedScope(recipient, this.scopes)`, which this handler was missing.
          assertAllowedScope(scope, discovery.scopes, 'aztec_utl_getPendingTaggedLogsV2');
          const provided = providedSecrets
            .readAll(ephemeral)
            .map(ps => new AppTaggingSecret(ps.secret, contract, ps.mode));
          const derived: AppTaggingSecret[] = [];
          const sender = discovery.tagging.senderForTags();
          if (sender !== undefined) {
            // THE SCOPE HOLDS THE LOCAL KEYS AND THE DIRECTION IS THE SCOPE. A recipient scanning
            // for logs sent to it derives with its OWN keys against the sender's address, and the
            // secret is directed at itself — see `DevTagging.appTaggingSecret`'s `direction`.
            const secret = await discovery.tagging.appTaggingSecret(scope, sender, contract, scope);
            if (secret) {
              derived.push(secret);
            }
          }
          // DEDUPLICATED, WHICH IS UPSTREAM'S OWN LINE AND ITS OWN REASON: *"these sources can
          // overlap (a sender that is also a PXE account, or a pre-shared secret that coincides with
          // a sender-derived one), so we deduplicate the combined set."* Without it a secret that
          // appears twice scans the same tags twice and returns THE SAME LOG TWICE — which is
          // precisely the double-count `test_tagging_index_advances`' own control is about, arriving
          // from the secret side instead of the index side.
          const secrets = Array.from(
            new Map([...provided, ...derived].map(s => [s.toString(), s])).values(),
          );

          // THE WINDOW IS BOUNDED AND THE BOUND IS THE CALLER'S. A scan with no bound over a hash
          // stream is not a search, it is a loop; and a window of zero would make "no logs found"
          // mean "nothing was looked for", which is the absence-measured-over-an-excluded-subject
          // shape this campaign has paid for three times.
          const window = discovery.taggingProbeWindow ?? 8;
          if (!Number.isInteger(window) || window < 1) {
            throw new Error(
              `aztec_utl_getPendingTaggedLogsV2: taggingProbeWindow must be a positive integer, got ` +
                `${String(window)}. A window of zero would report "no pending logs" without looking.`,
            );
          }
          const found: RetrievedTaggedLog[] = [];
          let probes = 0;
          for (const secret of secrets) {
            // THE RECIPIENT-SIDE INDEX, NOT THE SENDER-SIDE COUNTER. See `DevTagging`'s own comment:
            // probing from the sender's next reservation starts the scan one past the index the
            // sender just used, and reports zero over an index holding one.
            const from = discovery.tagging.recipientSyncedIndex(secret);
            for (let i = 0; i < window; i++) {
              const index = from + i;
              const tag = await discovery.tagging.siloedTag(secret, index, contract);
              probes += 1;
              const hits = discovery.noteDb.logsByTag(tag, undefined, discovery.anchorBlockNumber);
              if (hits.length > 0) {
                discovery.tagging.advanceRecipientSyncedIndex(secret, index);
              }
              found.push(...hits);
            }
          }
          record(
            'aztec_utl_getPendingTaggedLogsV2',
            'served',
            `scope=${scope.toString()} secrets=${secrets.length} (${provided.length} provided, ` +
              `${derived.length} derived) probes=${probes} logs=${found.length}`,
          );
          return EphemeralArray.fromValues(
            ephemeral,
            found.map(log => ({ log: [...log.fields], context: toResolvedTx(log) })),
          );
        },

        async getLogsByTagV2(
          requests: EphemeralArray<LogRetrievalRequest>,
        ): Promise<EphemeralArray<EphemeralArray<LogRetrievalResponse>>> {
          const list = requests.readAll(ephemeral);
          // UPSTREAM'S FIRST LINE, AND IT IS A CROSS-CONTRACT READ THIS HANDLER WOULD OTHERWISE
          // ALLOW. `LogService.fetchLogsByTag` refuses a request whose `contractAddress` is not the
          // executing frame's, by name. Without it a contract silos the tag with ANOTHER contract's
          // address and reads that contract's tagged logs — and the answer is well-formed either
          // way, so nothing downstream would notice. A first version of this file documented the
          // permissive behaviour in a comment as though it were the design, which is worse than
          // leaving it undocumented.
          for (const request of list) {
            if (!request.contractAddress.equals(contract)) {
              throw new Error(
                `aztec_utl_getLogsByTagV2: got a log retrieval request for ` +
                  `${request.contractAddress.toString()}, and this frame is executing as ` +
                  `${contract.toString()}. A contract may only read logs tagged for itself.`,
              );
            }
          }
          const inner: EphemeralArray<LogRetrievalResponse>[] = [];
          let total = 0;
          for (const request of list) {
            // THE TAG ON THE WIRE IS UNSILOED and the index is keyed by the siloed one — upstream's
            // `fetchLogsByTag` silos with the REQUEST's contract address, not with this frame's, so
            // a contract may ask about another contract's logs and gets that contract's tag.
            const siloedTag = (await SiloedTag.computeFromTagAndApp(request.tag, request.contractAddress)).value;
            const logs = discovery.noteDb.logsByTag(
              siloedTag,
              request.fromBlock.value as number | undefined,
              (request.toBlock.value as number | undefined) ?? discovery.anchorBlockNumber,
            );
            total += logs.length;
            inner.push(
              EphemeralArray.fromValues(
                ephemeral,
                logs.map(log => ({
                  // UPSTREAM'S OWN SLICE, COMMENT AND ALL: the tag is field 0 and the payload is
                  // clipped to the wire cap, because a public log can exceed the BoundedVec slot the
                  // oracle declares.
                  logPayload: [...log.fields].slice(1, 1 + PRIVATE_LOG_CIPHERTEXT_LEN),
                  txHash: TxHash.fromString(log.txHash),
                  uniqueNoteHashesInTx: [...log.noteHashes],
                  firstNullifierInTx: toResolvedTx(log).firstNullifierInTx,
                  blockNumber: log.blockNumber as never,
                  blockTimestamp: log.blockTimestamp as never,
                  blockHash: log.blockHash as never,
                })),
              ),
            );
          }
          record('aztec_utl_getLogsByTagV2', 'served', `requests=${list.length} logs=${total}`);
          return EphemeralArray.fromValues(ephemeral, inner);
        },

        async validateAndStoreEnqueuedNotesAndEvents(
          noteValidationRequests: EphemeralArray<NoteValidationRequest>,
          eventValidationRequests: EphemeralArray<unknown>,
          scope: AztecAddress,
        ): Promise<void> {
          const notes = noteValidationRequests.readAll(ephemeral);
          const events = eventValidationRequests.readAll(ephemeral);
          // EVENTS ARE REFUSED BY NAME RATHER THAN DROPPED. Upstream stores them in a
          // `PrivateEventStore` — another `AztecAsyncKVStore` consumer — and this wallet has none.
          // Accepting the request and storing nothing would make `getPrivateEvents` answer an empty
          // set that looks like "there were no events".
          if (events.length > 0) {
            throw new Error(
              `aztec_utl_validateAndStoreEnqueuedNotesAndEvents: ${events.length} event validation ` +
                'request(s) were enqueued and this wallet has no private-event store, so it refuses ' +
                'rather than dropping them. Notes are stored; events are not, and M34 already refuses ' +
                '`getPrivateEvents` by name for the same reason.',
            );
          }
          const stored = await discovery.noteDb.validateAndStoreNotes(
            notes.map(n => ({
              contractAddress: n.contractAddress,
              owner: n.owner,
              storageSlot: n.storageSlot,
              randomness: n.randomness,
              noteNonce: n.noteNonce,
              content: n.content,
              noteHash: n.noteHash,
              nullifier: n.nullifier,
              txHash: n.txHash.toString(),
            })),
            scope,
            discovery.anchorBlockNumber,
          );
          record(
            'aztec_utl_validateAndStoreEnqueuedNotesAndEvents',
            'served',
            `notes=${notes.length} stored=${stored} events=${events.length} scope=${scope.toString()}`,
          );
        },

        // ---- tagging ------------------------------------------------------------------------------
        async getAppTaggingSecret(sender: AztecAddress, recipient: AztecAddress): Promise<Option<Fr>> {
          // UPSTREAM'S `assertAllowedScope(sender, this.scopes)`. Its own doc says the only expected
          // `None` is an invalid RECIPIENT — a sender outside the scopes FAILS rather than returning
          // none, because "this wallet will not act for that account" and "that account has no
          // derivable secret" are different answers and only one of them is about the recipient.
          assertAllowedScope(sender, discovery.scopes, 'aztec_prv_getAppTaggingSecret');
          const secret = await discovery.tagging.appTaggingSecret(sender, recipient, contract);
          record(
            'aztec_prv_getAppTaggingSecret',
            'served',
            `sender=${sender.toString()} recipient=${recipient.toString()} held=${secret !== undefined}`,
          );
          // NONE IS THE HONEST ANSWER AND NOT A REFUSAL. `Option<Field>` is the declared return, and
          // the case it exists for is exactly this one: the wallet does not hold that sender's keys.
          // A fabricated field here would be a tagging secret nobody can re-derive.
          return secret === undefined ? Option.none<Fr>() : Option.some(secret.secret);
        },

        getNextTaggingIndex(secret: Fr, deliveryMode: AppTaggingSecretKind): number {
          const app = new AppTaggingSecret(secret, contract, deliveryMode);
          const index = discovery.tagging.nextTaggingIndex(app);
          record(
            'aztec_prv_getNextTaggingIndex',
            'served',
            `secret=${secret.toString()} mode=${String(deliveryMode)} index=${index}`,
          );
          return index;
        },

        getSenderForTags(): Option<AztecAddress> {
          const sender = discovery.tagging.senderForTags();
          record('aztec_prv_getSenderForTags', 'served', `sender=${sender?.toString() ?? 'none'}`);
          return sender === undefined ? Option.none<AztecAddress>() : Option.some(sender);
        },

        async resolveTaggingStrategy(
          sender: AztecAddress,
          recipient: AztecAddress,
          deliveryMode: AppTaggingSecretKind,
        ): Promise<unknown> {
          // THE SAME GUARD, because upstream's `#addressDerivedSecret` resolves through
          // `getAppTaggingSecret` and inherits it. Applied here rather than left to be inherited,
          // because this handler's strategy resolution does not go through that method.
          assertAllowedScope(sender, discovery.scopes, 'aztec_prv_resolveTaggingStrategy');
          const resolved = await discovery.tagging.resolveTaggingStrategy(
            sender,
            recipient,
            contract,
            deliveryMode,
          );
          record(
            'aztec_prv_resolveTaggingStrategy',
            'served',
            `sender=${sender.toString()} recipient=${recipient.toString()} type=${resolved.type}`,
          );
          return resolved;
        },
      }
    : {};

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
  for (const [method, fn] of Object.entries(discoveryServed)) {
    handler[method] = fn;
  }
  for (const oracle of discovery ? ORACLE_REFUSING_WITH_DISCOVERY : ORACLE_REFUSING) {
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
    discovery !== undefined,
  );

  return {
    handler,
    calls: () => calls,
    contractVersion: () => contractVersion,
    hasDiscovery: () => discovery !== undefined,
    servedSet: () => (discovery ? ORACLE_IMPLEMENTED_WITH_DISCOVERY : ORACLE_IMPLEMENTED),
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
