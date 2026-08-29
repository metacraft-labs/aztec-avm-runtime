// dev_wallet.ts — the CodeTracer dev wallet: deterministic keys, public entrypoints, and every
// decision on the record.
//
// ===========================================================================================
// WHAT THIS FILLS, AND WHY IT IS A SUBSTITUTION RATHER THAN A CONSTRUCTION.
// ===========================================================================================
//
// M33 shipped the seam with a NULL WALLET in it — one that refuses all sixteen of upstream's
// `WalletSchema` methods by name — so that "the runtime has no wallet attached" was a statement
// about an exercised boundary rather than an absent one. M34 puts a wallet there. Nothing about
// the transport, the protocol, the handshake or the disclosure changes: `PortConnectionHandler`'s
// `getWallet` callback returns this object instead of the null one, and every call still crosses
// an AES-256-GCM session as a `SECURE_MESSAGE`.
//
// ===========================================================================================
// THE DESIGN GOAL, WRITTEN DOWN SO NOBODY LATER "HARDENS" IT INTO USELESSNESS.
// ===========================================================================================
//
// A production wallet guards keys and hides its reasoning. **A debugging wallet must do the
// opposite**: every oracle call visible, every decision explicable, keys deterministic so a
// recording replays identically. These are properties a real wallet CANNOT have and a CodeTracer
// wallet SHOULD. Three concrete consequences, each of which a check reads:
//
//   1. **No ambient randomness.** The seed is an argument and lives in the trace metadata. See
//      `dev_keys.ts`; DD-4's discipline, applied to entropy.
//   2. **Every decision is a record.** `decisions()` is an ordered ledger of every method call,
//      what the wallet decided and why. `verify_wallet_decisions_appear_in_trace` requires those
//      records to be IN THE CONTAINER, read back through the pinned reader — a ledger that lived
//      only in a host variable would be a claim ABOUT a recording rather than a property OF one.
//   3. **Everything unserved refuses BY NAME.** The campaign's standing rule, and it matters most
//      here: a fabricated note or nullifier produces a transaction that LOOKS valid.
//
// ===========================================================================================
// `BaseWallet` IS NOT SUBCLASSED, AND THAT IS A MEASUREMENT WITH FOUR PARTS.
// ===========================================================================================
//
// M34's plan said "`BaseWallet` (666 lines) — subclass it; do not reinvent `getAccounts`,
// `getChainInfo`, `registerSender`, `registerContractClass`, `getContractMetadata`". That was the
// right instruction to give and the measurement says no. `DEV-WALLET.md` §2 carries the numbers;
// the four parts are:
//
//   1. **The package.** `@aztec/wallet-sdk`'s own `dependencies` names `@aztec/pxe`, whose closure
//      reaches `@aztec/simulator` and through it `@aztec/native` and `@aztec/world-state`. That is
//      RI-88, measured in M33, and it is why the protocol types are vendored rather than depended
//      on.
//   2. **The vendoring cost.** `base-wallet/index.ts`'s own value-reachable closure at the anchor is
//      **656 files and 79,060 lines across 15 workspace packages**, reaching `@aztec/pxe` AND
//      `@aztec/simulator` directly through three named VALUE edges. "666 lines" is the file; 79,060
//      is what taking it costs.
//   3. **The constructor.** `protected constructor(protected readonly pxe: PXE, protected readonly
//      aztecNode: AztecNode, …)`. It does not merely import PXE, it REQUIRES an instance. This
//      runtime has none by design, and a subclass that handed it a fabricated one would be the
//      plausible default this campaign refuses.
//   4. **What the five named methods actually contain.** Read at the anchor, one by one:
//      `getAccounts` is `abstract` — there is no body to inherit; `registerContractClass` is
//      `return this.pxe.registerContractClass(artifact)`; `registerSender` is one
//      `this.pxe.registerTaggingSecretSource(…)`; `getChainInfo` is two lines over
//      `aztecNode.getNodeInfo()`; and `getContractMetadata` is `this.pxe.getContractInstance` plus
//      three `aztecNode` calls. **Between them they contain zero lines of reusable logic that do
//      not require a `PXE`.** The 666 lines are almost entirely `simulateTx` / `profileTx` /
//      `completeFeeOptions` — the private-execution path M35 owns.
//
//   (And a fifth, smaller: `base_wallet.ts` opens with `import { inspect } from 'util'`, a Node
//   builtin, which M28's browser gate refuses outright.)
//
// So the decision is **replace**, recorded as RI-95 with `cannot-reach-target`, and what IS reused
// is the part that reuses: upstream's `WalletSchema` for the method list (RI-89, unchanged from
// M33), upstream's own zod codecs for every argument and return this wallet exchanges, upstream's
// `deriveKeys`/`computeAddress` for the keys, and M26's vendored transaction builder for the
// calldata.
//
// ===========================================================================================
// THE PUBLIC-ONLY ENTRYPOINT SHAPE IS UPSTREAM'S, AND M21 ALREADY DELIVERED AGAINST IT.
// ===========================================================================================
//
// `wallet-sdk/src/base-wallet/utils.ts`'s `simulateBatchViaNode` builds, in upstream's own words, a
// *"Minimal entrypoint structure — no real private execution, just public call requests"*: an empty
// `PrivateCallExecutionResult` whose `publicCallRequests` are the calls and whose `feePayer` is the
// sender. That is the shape, and it is exactly the shape M21's Form B and M26's vendored
// `PublicTxSimulationTester` already produce — `createTxForPublicCalls` (RI-72,
// `PROVENANCE.md` F20–F24) builds the same object without going through `@aztec/pxe/simulator`'s
// `generateSimulatedProvingResult`, which is one of the three pxe VALUE edges above.
//
// So `sendTx` here is: check the calls, derive each selector FROM THE ARTIFACT the wallet itself
// registered, refuse by name on any disagreement, hand the calls to the vendored builder, and
// submit. `DefaultEntrypoint` — upstream's other entrypoint — is not usable and the reason is one
// line of its own source: `if (call.type !== FunctionType.PRIVATE) throw new Error('Public
// entrypoints are not allowed');`.

// `import type`, AND IT IS A BUILD PROPERTY RATHER THAN A STYLE CHOICE. `Fr` and `AztecAddress`
// appear in this file only in TYPE positions, and a VALUE import of a name used only as a type
// leaves an edge in the esbuild metafile marked `external: true` — while an `import type` clause is
// elided outright and leaves none. Measured: with the value spelling,
// `verify_browser_bundle_no_node_builtins` went from "exactly one non-inject external edge" to
// three, and `verify_browser_bundle_no_native_deps`'s pinned external SET grew by two. The bundle
// worked either way; the pin is what noticed, which is what a pinned set is for.
import type { Fr } from '@aztec/foundation/curves/bn254';
import { type Wallet, WalletSchema } from '@aztec/aztec.js/wallet';
import { type ContractArtifact, FunctionSelector } from '@aztec/stdlib/abi';
import type { AztecAddress } from '@aztec/stdlib/aztec-address';
import { makeContractClassPublic } from '@aztec/stdlib/testing';

import {
  getContractFunctionArtifact,
  getFunctionSelector,
} from '../../../orchestration/src/vendor/avm_fixtures_utils.ts';
import { PublicTxSimulationTester } from '../../../orchestration/src/vendor/public_tx_simulation_tester.ts';
import { SimpleContractDataSource } from '../../../orchestration/src/vendor/simple_contract_data_source.ts';

import { DEFAULT_DEV_WALLET_SEED, type DevAccount, deriveDevAccounts, parseDevWalletSeed } from './dev_keys.ts';

/** This wallet's name, as it announces itself in `requestCapabilities`' answer. */
export const DEV_WALLET_NAME = 'CodeTracer dev wallet';

/** This wallet's version. */
export const DEV_WALLET_VERSION = '0.34.0';

/** Every method name upstream's `WalletSchema` declares, read from the schema rather than typed. */
export const DEV_WALLET_METHODS: readonly string[] = Object.freeze(Object.keys(WalletSchema).sort());

/**
 * The methods this wallet SERVES.
 *
 * DECLARED HERE AND CHECKED AGAINST THE OBJECT THAT ACTUALLY SERVES THEM, at construction, by
 * {@link createDevWallet} — which throws naming the difference in either direction. The list cannot
 * be built FROM that object, because the object closes over the host and the options and does not
 * exist until a wallet is constructed; so the two are separate and the guard is what keeps them
 * from drifting. **The guard is not the whole evidence**: `e2e_wallet_public_transfer` calls all ten
 * of these across the encrypted session and reads the wallet's own ledger for each, and calls all
 * six of {@link DEV_WALLET_REFUSED} and requires each to refuse by name — sixteen of sixteen
 * exercised behaviourally, which is the half a construction-time check cannot give.
 */
export const DEV_WALLET_SERVED: readonly string[] = Object.freeze(
  [
    'getAccounts',
    'getAddressBook',
    'getChainInfo',
    'getContractClassMetadata',
    'getContractMetadata',
    'registerContract',
    'registerContractClass',
    'registerSender',
    'requestCapabilities',
    'sendTx',
  ].sort(),
);

/**
 * The methods this wallet REFUSES, each naming what would have to exist for it to stop.
 *
 * Derived rather than listed: the refused set is `WalletSchema`'s keys minus the served ones, so a
 * seventeenth method upstream adds is refused on the day the pin moves, with no edit here — which
 * is M33's `NULL_WALLET_METHODS` property carried forward rather than restated.
 */
export const DEV_WALLET_REFUSED: readonly string[] = Object.freeze(
  DEV_WALLET_METHODS.filter(m => !DEV_WALLET_SERVED.includes(m)),
);

/** Why each refused method is refused. Every entry names the milestone that would serve it. */
export const DEV_WALLET_REFUSAL_REASONS: Readonly<Record<string, string>> = Object.freeze({
  getPrivateEvents:
    'private events need note discovery and tagging, which is M36; this wallet has no note database',
  simulateTx:
    'simulateTx runs the account entrypoint through private execution, which is M35; this wallet '
    + 'serves public entrypoints only',
  profileTx:
    'profiling needs the private circuit gate counts, which is M35; there is no private execution here',
  executeUtility:
    'utility functions execute in the private simulator, which is M35',
  createAuthWit:
    'an authwit is a signature over an intent by an account contract, which needs private execution '
    + '(M35) and an account contract this wallet does not deploy',
  batch:
    'batching is upstream\'s own request batching over this boundary; M34 crosses one call at a '
    + 'time on purpose, so that every decision has its own trace record',
});

/** Thrown by every refused method. The method name is a FIELD, not a substring to parse. */
export class DevWalletRefused extends Error {
  override readonly name = 'DevWalletRefused';

  constructor(
    /** The wallet method that was called. */
    readonly method: string,
    /** Why it is refused, and what would have to exist for it to stop. */
    readonly reason: string,
  ) {
    super(`DevWalletRefused: the CodeTracer dev wallet does not serve '${method}': ${reason}`);
  }
}

/** Thrown when the wallet declines to authorize a transaction. The control's named failure. */
export class DevWalletAuthorizationDeclined extends Error {
  override readonly name = 'DevWalletAuthorizationDeclined';

  constructor(
    /** The account the transaction was to be sent from. */
    readonly from: string,
    /** Why the wallet declined. */
    readonly reason: string,
  ) {
    super(`DevWalletAuthorizationDeclined: the wallet declined to authorize a transaction from ${from}: ${reason}`);
  }
}

/** One entry in the wallet's decision ledger. */
export interface WalletDecision {
  /** Monotonic sequence number within this wallet. */
  readonly seq: number;
  /** The `WalletSchema` method that was called. */
  readonly method: string;
  /** What the wallet decided. */
  readonly decision: 'served' | 'refused' | 'authorized' | 'declined';
  /** A sentence naming the subject, never a bare word. */
  readonly detail: string;
}

/**
 * What the wallet needs from the node side.
 *
 * IT IS AN INTERFACE AND NOT AN IMPORT, and that is DD-11 rather than taste: `wallet.js` is a
 * separate entry point precisely so that a page which attaches no wallet does not download the
 * protocol, and a wallet that imported `openAvmRuntime` would drag the whole runtime into it in the
 * other direction. The demo page supplies this over an `OpenedRuntime` in four lines.
 */
export interface DevWalletHost {
  /** The chain this wallet is attached to. */
  chainInfo(): Promise<{ chainId: Fr; version: Fr }>;
  /** Put a contract class in the node's resident store. Returns how many were newly registered. */
  registerContractClass(contractClass: unknown): Promise<number>;
  /** Put a contract instance in the node's resident store. */
  registerContractInstance(instance: unknown): Promise<number>;
  /** Whether the node knows an instance at this address. */
  isPublished(address: AztecAddress): Promise<boolean>;
  /** Whether the address's initialization nullifier is in the node's nullifier tree. */
  isInitialized(address: AztecAddress): Promise<boolean>;
  /** Submit a built public transaction and seal it. */
  submitPublicTx(tx: unknown): Promise<{ txHash: string }>;
}

/** Options for {@link createDevWallet}. */
export interface DevWalletOptions {
  /** The node side. */
  host: DevWalletHost;
  /** The recorded seed. Defaults to {@link DEFAULT_DEV_WALLET_SEED}. Never generated. */
  seed?: string | Fr;
  /** How many accounts to derive. Defaults to 2 — a sender and a recipient. */
  accounts?: number;
  /**
   * THE CONTROL. When set, the wallet declines to authorize any transaction, by name.
   *
   * The milestone's own words: *"a wallet refusing to sign produces a named failure, not a silent
   * no-op"*. A control that lives in the subject and runs through the same dispatch is M32's
   * review's rule — a control beside the instrument constrains its own code and not the subject's.
   */
  declineAuthorization?: string | undefined;
  /**
   * THE SECOND CONTROL. Decision kinds named here are not written to the ledger.
   *
   * `verify_wallet_decisions_appear_in_trace` needs a run that is missing EXACTLY one record, and
   * suppressing it here — rather than editing the container afterwards — means the suppression
   * travels the same path the record does.
   *
   * A SUPPRESSED DECISION STILL CONSUMES ITS SEQUENCE NUMBER, so the ledger carries a visible GAP
   * rather than a renumbered run. That is deliberate and it is the design goal in miniature: a
   * debugging wallet should make a withheld decision legible, not seamless. It is also why the
   * check compares the two containers on the (method, decision) pair rather than on whole rows —
   * every later `seq=` shifts otherwise, and a comparison that failed on all of them would say
   * nothing about which record went missing.
   */
  suppressDecisions?: readonly string[];
}

/** The wallet plus the bookkeeping that makes its decisions facts about the object. */
export interface DevWalletHandle {
  /** The wallet, satisfying upstream's `Wallet` interface. */
  readonly wallet: Wallet;
  /** The seed this wallet was built from, as it goes into the trace metadata. */
  readonly seed: string;
  /** The accounts derived from it. */
  accounts(): readonly DevAccount[];
  /** Every decision, in order. */
  decisions(): readonly WalletDecision[];
  /** The contract artifacts this wallet holds, by class id. */
  artifactCount(): number;
}

/**
 * The artifact-hash seed `makeContractClassPublic` is given.
 *
 * `token_transfer.ts` passes 27 on the direct path; the same value is passed here so the class the
 * wallet derives and the class the direct shortcut derives are the SAME object, which is what
 * `test_deployment_through_wallet` compares. A different seed here would make the two routes
 * produce different class ids and turn that comparison into a tautology about two unrelated things.
 */
export const CLASS_ARTIFACT_HASH_SEED = 27;

/** The metadata key each decision is written into the trace under. */
export const WALLET_DECISION_METADATA = 'ct.wallet-decision';

/** The metadata key the seed is written into the trace under. */
export const WALLET_SEED_METADATA = 'ct.wallet-seed';

/**
 * Render one decision as the content of a `TraceLogEvent`.
 *
 * The shape is `key=value` pairs on one line, for the reason `STEP_PRODUCER_METADATA` uses the same
 * shape: `ct-print --full` prints a log event's content verbatim, so a check reads fields out of
 * the CONTAINER rather than out of the producer's report about itself.
 *
 * @param d - the decision
 * @returns the log content
 */
export function renderWalletDecision(d: WalletDecision): string {
  return `seq=${d.seq} method=${d.method} decision=${d.decision} detail=${d.detail}`;
}

/**
 * Build the CodeTracer dev wallet.
 *
 * @param options - the host, the seed and the two controls
 * @returns the wallet and its ledgers
 */
export async function createDevWallet(options: DevWalletOptions): Promise<DevWalletHandle> {
  const host = options.host;
  const seed = parseDevWalletSeed(options.seed ?? DEFAULT_DEV_WALLET_SEED);
  const accounts = await deriveDevAccounts(seed, options.accounts ?? 2);
  const suppressed = new Set(options.suppressDecisions ?? []);

  const decisions: WalletDecision[] = [];
  let seq = 0;
  const record = (method: string, decision: WalletDecision['decision'], detail: string): void => {
    const entry = { seq: seq++, method, decision, detail };
    if (suppressed.has(decision)) {
      return;
    }
    decisions.push(entry);
  };

  // The wallet's own view of the world: senders it was told about, artifacts it was given, and the
  // instances it registered. All three are the wallet's, not the node's — which is the point of the
  // seam: the node holds bytecode and state, the wallet holds who and what it knows about.
  const senders: { alias: string; item: AztecAddress }[] = [];
  const artifacts = new Map<string, ContractArtifact>();
  const artifactByAddress = new Map<string, ContractArtifact>();
  const instances = new Map<string, unknown>();

  // The vendored builder's FALLBACK artifact lookup, and nothing more: every enqueued call this
  // wallet builds carries its own `contractArtifact`, taken from the registry above, so the builder
  // never consults this. It exists because `PublicTxSimulationTester`'s constructor requires one,
  // and leaving it empty is what makes "the artifact the AVM dispatches against is the one the
  // WALLET registered" true by construction rather than by convention.
  const dataSource = new SimpleContractDataSource();

  // Declared above, defined below, and reconciled between the two before the wallet exists — see
  // `assertServedMatchesDeclaration`.
  const served: Record<string, (...args: never[]) => Promise<unknown>> = {
    getChainInfo: async () => {
      const info = await host.chainInfo();
      record('getChainInfo', 'served', `chainId=${info.chainId.toString()} version=${info.version.toString()}`);
      return info;
    },

    getAccounts: async () => {
      record('getAccounts', 'served', `${accounts.length} account(s) derived from the recorded seed`);
      return accounts.map((a, i) => ({ alias: `dev-${i}`, item: a.address }));
    },

    getAddressBook: async () => {
      record('getAddressBook', 'served', `${senders.length} registered sender(s)`);
      return senders.map(s => ({ alias: s.alias, item: s.item }));
    },

    registerSender: async (address: AztecAddress, alias?: string) => {
      const key = address.toString();
      if (!senders.some(s => s.item.toString() === key)) {
        senders.push({ alias: alias ?? '', item: address });
      }
      record('registerSender', 'served', `sender=${key}`);
      return address;
    },

    registerContractClass: async (artifact: ContractArtifact) => {
      // DELIVERABLE 4, THE FIRST HALF: registration goes THROUGH the wallet.
      //
      // The wallet derives the class from the artifact with upstream's own `makeContractClassPublic`
      // — the same call `token_transfer.ts` makes on the direct path, so the two routes produce the
      // same object and `test_deployment_through_wallet` can compare them rather than take the
      // wallet's word — and hands it to the node. The wallet keeps the ARTIFACT (which the node has
      // no use for) and the node keeps the BYTECODE (which the wallet has no use for). That split
      // is the seam.
      const name = artifact.name;
      const dispatch = getContractFunctionArtifact('public_dispatch', artifact);
      if (dispatch === undefined) {
        record('registerContractClass', 'refused', `artifact=${name} has no public_dispatch`);
        throw new DevWalletRefused(
          'registerContractClass',
          `the artifact '${name}' declares no public_dispatch function, so it has no public bytecode `
          + 'for a public-entrypoint wallet to register',
        );
      }
      const contractClass = await makeContractClassPublic(CLASS_ARTIFACT_HASH_SEED, dispatch.bytecode);
      const registered = await host.registerContractClass(contractClass);
      artifacts.set(contractClass.id.toString(), artifact);
      record(
        'registerContractClass',
        'served',
        `artifact=${name} classId=${contractClass.id.toString()} registered=${registered} `
        + `functions=${artifact.functions.length}`,
      );
      return undefined;
    },

    registerContract: async (
      instance: { address: AztecAddress; currentContractClassId?: Fr; originalContractClassId?: Fr },
      artifact?: ContractArtifact,
    ) => {
      // DELIVERABLE 4, THE SECOND HALF — and the artifact is found by CLASS ID rather than sent
      // again. `registerContract`'s artifact argument is optional in upstream's own schema, and
      // sending the Token artifact twice would put seven megabytes through the AES-GCM session for
      // a value the wallet already holds. So the class id the instance carries is the key, and a
      // caller who registers an instance of a class this wallet has never seen gets a refusal from
      // `sendTx` naming the address — not a plausible default.
      const address = instance.address.toString();
      const classId = (instance.currentContractClassId ?? instance.originalContractClassId)?.toString();
      const held = artifact ?? (classId !== undefined ? artifacts.get(classId) : undefined);
      if (artifact !== undefined && classId !== undefined) {
        artifacts.set(classId, artifact);
      }
      if (held !== undefined) {
        artifactByAddress.set(address, held);
      }
      instances.set(address, instance);
      const n = await host.registerContractInstance(instance);
      record(
        'registerContract',
        'served',
        `instance=${address} classId=${classId ?? 'none'} registered=${n} `
        + `artifact=${held ? held.name : 'none'}`,
      );
      // IT RETURNS THE INSTANCE, AND THAT IS THE INSTALLED PIN'S SCHEMA RATHER THAN THE ANCHOR'S.
      //
      // `wallet.ts` at the `cpp` anchor declares `registerContract`'s `output: z.void()`. The
      // PUBLISHED `@aztec/aztec.js@5.0.0-nightly.20260626` — the pin this repository depends on, and
      // the object `NULL_WALLET_METHODS` and this wallet both read their method list out of —
      // declares an INTERSECTION of the instance preimage with `{address}`. Measured, both ways,
      // rather than read: `getSchemaReturnType(WalletSchema.registerContract)` is `intersection` at
      // the pin, and returning `undefined` fails it. The first run of the wallet demo failed
      // exactly there, with two union issues at an empty path and nothing naming the method — which
      // is why `callWallet` in the demo attaches the name now.
      //
      // The same disagreement is one method along: `registerSender`'s output is a UNION at the pin
      // (an `AztecAddress` through two codecs) where the anchor declares `schemas.AztecAddress`.
      // `DEV-WALLET.md` section 5 records both, because "the anchor and the installed pin are two
      // different things" is a fact this campaign has already paid for once, at M23's
      // `AztecNodeDebug` — five methods at the anchor, three at the pin.
      return instance;
    },

    getContractMetadata: async (address: AztecAddress) => {
      const key = address.toString();
      const instance = instances.get(key);
      const published = await host.isPublished(address);
      const initialized = await host.isInitialized(address);
      record(
        'getContractMetadata',
        'served',
        `address=${key} known=${instance !== undefined} published=${published} initialized=${initialized}`,
      );
      return {
        instance: instance as never,
        // Upstream's own `ContractInitializationStatus`, whose members are STRINGS — read from the
        // node's nullifier tree rather than assumed, which is the same question `BaseWallet` asks
        // its `aztecNode` and the only part of that method that is not a `pxe` call.
        initializationStatus: initialized ? 'INITIALIZED' : 'UNINITIALIZED',
        isContractPublished: published,
        isContractUpdated: false,
      };
    },

    getContractClassMetadata: async (id: Fr) => {
      // KEYED BY THE ID, not by the size of the map. `artifacts.size > 0` would answer `true` for
      // every id the moment one class was registered — an assertion that cannot fail, wearing the
      // shape of a lookup. The check asks this of a registered id AND of a fabricated one.
      const known = artifacts.has(id.toString());
      record(
        'getContractClassMetadata',
        'served',
        `classId=${id.toString()} known=${known} artifactsHeld=${artifacts.size}`,
      );
      return { isArtifactRegistered: known, isContractClassPubliclyRegistered: known };
    },

    requestCapabilities: async (manifest: { metadata?: { name?: string; version?: string; description?: string } }) => {
      // §8.4 ACROSS THE BOUNDARY, and M33 already built the carrier. What changes in M34 is that
      // the wallet now ANSWERS instead of refusing: it grants nothing (this wallet has no
      // capabilities to grant that the caller does not already have) and it records that it was
      // told, which is the half the milestone requires.
      record(
        'requestCapabilities',
        'served',
        `app=${manifest?.metadata?.name ?? 'unnamed'} version=${manifest?.metadata?.version ?? 'none'} `
        + `disclosed=${manifest?.metadata?.description !== undefined}`,
      );
      return {
        version: '1.0' as const,
        granted: [],
        wallet: { name: DEV_WALLET_NAME, version: DEV_WALLET_VERSION },
      };
    },

    sendTx: async (payload: ExecutionPayloadLike, opts: { from?: unknown }) => {
      const from = opts?.from as AztecAddress | undefined;
      const fromKey = from ? from.toString() : 'none';

      // ---- THE SIGNING DECISION -------------------------------------------------------------
      //
      // A public entrypoint carries no signature, and that does not make the decision go away: the
      // wallet still decides whether to authorize a transaction from one of ITS accounts. Both
      // answers are named, both are recorded, and the declining branch is the milestone's own
      // control — "a wallet refusing to sign produces a named failure, not a silent no-op".
      if (options.declineAuthorization !== undefined) {
        record('sendTx', 'declined', `from=${fromKey} reason=${options.declineAuthorization}`);
        throw new DevWalletAuthorizationDeclined(fromKey, options.declineAuthorization);
      }
      const owned = accounts.find(a => from !== undefined && a.address.toString() === fromKey);
      if (owned === undefined) {
        record('sendTx', 'declined', `from=${fromKey} reason=not-an-account-of-this-wallet`);
        throw new DevWalletAuthorizationDeclined(
          fromKey,
          `it is not one of this wallet's ${accounts.length} deterministically derived accounts `
          + `(${accounts.map(a => a.address.toString()).join(', ')})`,
        );
      }
      record(
        'sendTx',
        'authorized',
        `from=${fromKey} accountIndex=${owned.index} calls=${payload.calls.length}`,
      );

      // ---- THE CALLDATA, WITH THE SELECTOR RE-DERIVED FROM THE ARTIFACT ----------------------
      //
      // The caller hands over `FunctionCall`s that already carry a selector. The wallet does not
      // take that on trust: it looks the function up in the artifact IT registered and compares.
      // A disagreement is a refusal that names both selectors, because a wallet that dispatched to
      // whatever selector it was handed would be a wallet that signs whatever it is given.
      const enqueued: { address: AztecAddress; args: Fr[]; isStaticCall: boolean; contractArtifact: ContractArtifact }[] = [];
      for (const call of payload.calls) {
        const address = call.to.toString();
        const artifact = artifactByAddress.get(address);
        if (artifact === undefined) {
          record('sendTx', 'refused', `to=${address} reason=no-artifact-registered-for-this-address`);
          throw new DevWalletRefused(
            'sendTx',
            `no artifact is registered for ${address}; registerContract(instance, artifact) must run `
            + 'through this wallet before it will build calldata for that contract',
          );
        }
        const declared = FunctionSelector.fromField(call.selector.toField());
        const derived = await getFunctionSelector(call.name, artifact);
        if (!derived.equals(declared)) {
          record(
            'sendTx',
            'refused',
            `fn=${call.name} declaredSelector=${declared.toString()} derivedSelector=${derived.toString()}`,
          );
          throw new DevWalletRefused(
            'sendTx',
            `the call to '${call.name}' declares selector ${declared.toString()}, but the artifact `
            + `this wallet registered derives ${derived.toString()}`,
          );
        }
        enqueued.push({
          address: call.to,
          // The vendored builder's no-`fnName` branch takes the calldata verbatim and prepends
          // nothing, which is what lets the SELECTOR the wallet derived be the one the AVM receives.
          args: [derived.toField(), ...call.args],
          isStaticCall: call.isStatic === true,
          contractArtifact: artifact,
        });
      }

      // ---- THE PUBLIC-ONLY ENTRYPOINT ---------------------------------------------------------
      //
      // M26's vendored builder (RI-72, `PROVENANCE.md` F20–F24), used exactly as
      // `token_transfer.ts` uses it, with the same world-state TRIPWIRE: its one removed dependency
      // is `MerkleTreeWriteOperations`, and a proxy that throws on every access is what makes "the
      // builder never touches a world state" a failure rather than a sentence.
      const touched: string[] = [];
      const tripwire = new Proxy(
        {},
        {
          get(_t, p) {
            touched.push(`get:${String(p)}`);
            throw new Error(`the dev wallet's transaction builder read merkleTree.${String(p)}`);
          },
          has(_t, p) {
            touched.push(`has:${String(p)}`);
            throw new Error(`the dev wallet's transaction builder asked '${String(p)}' in merkleTree`);
          },
          ownKeys() {
            touched.push('ownKeys');
            throw new Error('the dev wallet\'s transaction builder enumerated merkleTree');
          },
        },
      );
      const tester = new PublicTxSimulationTester(tripwire as never, dataSource);
      const tx = await tester.createTx(owned.address, [], enqueued as never, undefined, owned.address);

      const receipt = await host.submitPublicTx(tx);
      record(
        'sendTx',
        'served',
        `txHash=${receipt.txHash} calls=${enqueued.length} merkleTouches=${touched.length}`,
      );
      // `TxHash.schema` parses the `0x`-prefixed 32-byte hex the facade's receipt already carries,
      // so the value that crosses the encrypted boundary is the node's own hash rather than a
      // re-derivation of it. `offchainEffects` and `offchainMessages` are empty and are REQUIRED
      // fields of upstream's `OffchainOutputSchema`: a public transaction produces neither, and
      // omitting them would be refused by upstream's codec on the caller's side.
      return { txHash: receipt.txHash, offchainEffects: [], offchainMessages: [] };
    },
  };

  // THE DECLARATION AND THE IMPLEMENTATION, RECONCILED, BEFORE ANYTHING CAN CALL EITHER.
  //
  // `DEV_WALLET_SERVED` is a list a check reads and `DEV_WALLET_REFUSAL_REASONS` is a map a refusal
  // quotes; both are separate from the `served` object above and from each other, and three
  // separate declarations of one partition is three things to drift. This is the reconciliation,
  // and it throws NAMING the difference rather than letting a method be listed as served and
  // silently refuse — which is the campaign's plausible-default shape wearing a table of contents.
  assertServedMatchesDeclaration(Object.keys(served));

  const target = {} as Record<string, unknown>;
  const declared = new Set(DEV_WALLET_METHODS);
  const wallet = new Proxy(target, {
    get: (_t, prop) => {
      const name = typeof prop === 'symbol' ? prop.toString() : prop;
      if (!declared.has(name)) {
        // Not a wallet method at all — `then`, `toJSON`, inspection symbols. Returning a function
        // for these makes the object look thenable and hangs the first `await`. M33's finding,
        // kept.
        return undefined;
      }
      const impl = served[name];
      if (impl) {
        return (...args: unknown[]) => impl(...(args as never[]));
      }
      return (..._args: unknown[]) => {
        const reason = DEV_WALLET_REFUSAL_REASONS[name]
          ?? 'this wallet serves public entrypoints only; see DEV-WALLET.md section 3';
        record(name, 'refused', reason);
        return Promise.reject(new DevWalletRefused(name, reason));
      };
    },
    has: (_t, prop) => declared.has(typeof prop === 'symbol' ? prop.toString() : prop),
    ownKeys: () => [...DEV_WALLET_METHODS],
    getOwnPropertyDescriptor: () => ({ configurable: true, enumerable: true, value: undefined }),
  }) as unknown as Wallet;

  return {
    wallet,
    seed: seed.toString(),
    accounts: () => accounts,
    decisions: () => decisions,
    artifactCount: () => artifacts.size,
  };
}

/**
 * Reconcile the served DECLARATION with the served IMPLEMENTATION, in both directions.
 *
 * @param implemented - the keys of the object that actually answers
 * @throws when the two disagree, naming which names are on which side
 */
export function assertServedMatchesDeclaration(implemented: readonly string[]): void {
  const declared = new Set(DEV_WALLET_SERVED);
  const actual = new Set(implemented);
  const missing = [...declared].filter(n => !actual.has(n)).sort();
  const extra = [...actual].filter(n => !declared.has(n)).sort();
  const undeclaredReasons = DEV_WALLET_REFUSED.filter(n => DEV_WALLET_REFUSAL_REASONS[n] === undefined);
  if (missing.length > 0 || extra.length > 0 || undeclaredReasons.length > 0) {
    throw new Error(
      'the CodeTracer dev wallet\'s declared surface and its implementation disagree: '
      + `DEV_WALLET_SERVED names [${missing.join(', ')}] that nothing implements; `
      + `the implementation serves [${extra.join(', ')}] that DEV_WALLET_SERVED does not name; `
      + `and [${undeclaredReasons.join(', ')}] are refused with no reason declared.`,
    );
  }
}

/** The `FunctionCall`-shaped calls a payload carries, as this file reads them. */
interface ExecutionPayloadLike {
  /** The enqueued calls. */
  readonly calls: readonly {
    /** The callee. */
    readonly to: AztecAddress;
    /** The function name, which the wallet looks up in its own artifact. */
    readonly name: string;
    /** The selector the caller declares, which the wallet re-derives and compares. */
    readonly selector: { toField(): Fr };
    /** The already-encoded arguments. */
    readonly args: Fr[];
    /** Whether the call is static. */
    readonly isStatic?: boolean;
  }[];
}
