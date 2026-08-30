// M36 — tagging, derived from the wallet's DETERMINISTIC keys.
//
// ===========================================================================================
// THE DERIVATION IS UPSTREAM'S, AND IT IS READ FROM THE INSTALLED PIN RATHER THAN THE ANCHOR
// ===========================================================================================
//
// `AppTaggingSecret`, `AppTaggingSecretKind`, `Tag` and `SiloedTag` are `@aztec/stdlib/logs`'
// own — a package `orchestration/package.json` already declares — so nothing here re-derives a
// tagging secret by hand. **The plan's vocabulary for this was three months stale**:
// `computeAppTaggingSecret`, `computeTaggingSecretPoint`, `IndexedTaggingSecret`,
// `getIndexedTaggingSecretAsSender`, `deriveTaggingSecret`, `computeSiloedTagFromSecret` and
// `computeTagFromSecret` return ZERO hits anywhere at the `cpp` anchor. Measured, not assumed.
//
// AND THE INSTALLED PIN DISAGREES WITH THE ANCHOR — the fourth instance of the family
// `CAMPAIGN-BRIEF.md` records for `AztecNodeDebug`, for two zod schemas and for
// `AztecAddress.fromFieldUnsafe`:
//
//   | symbol                     | `cpp` anchor                                          | installed pin                    |
//   |----------------------------|-------------------------------------------------------|----------------------------------|
//   | `AppTaggingSecret` statics | `computeDirectional`, `computeAppSiloed`, `computeViaEcdh` | **`computeUnconstrained` only** |
//   | the ECDH helper            | exported `computeSharedTaggingSecret`                  | **not exported**; `deriveAppSiloedSharedSecret` instead |
//
// Three missing STATICS, which is not a missing export and therefore not a build failure — it is
// the shape M35 met inside the ACVM at run time. This file is written against
// `computeUnconstrained`, which is what will actually parse, and the vendored WIRE is unaffected
// because it imports only `AppTaggingSecretKind`, `appTaggingSecretKindFromDeliveryMode` and `Tag`,
// all three of which exist at the pin.
//
// ===========================================================================================
// NO AMBIENT RANDOMNESS, AND THIS IS WHERE UPSTREAM'S OWN CODE WOULD HAVE INTRODUCED SOME
// ===========================================================================================
//
// `DEV-WALLET.md` §1's third design property is deterministic keys, and `PRIVATE-EXECUTION.md` §5
// records the one place upstream's own code sits on the other side of it:
// `EphemeralArrayService.allocateSlot` is `do { slot = Fr.random(); } while (…)`, so **serialising
// any oracle return that carries an `EphemeralArray` reads ambient entropy** — which is why M35
// refused the four `fact` oracles with a measurement rather than a plan.
//
// **M36 has to answer that measurement rather than inherit it**, because two of its own eight
// returns are ephemeral arrays (`getPendingTaggedLogsV2` and `getLogsByTagV2`, the latter nested one
// deep). The answer is `DeterministicEphemeralArrayService` below, and it is upstream's OWN
// injection point rather than an edit: `EphemeralArray.fromValues(service, values)` takes the
// service from the CALLER, `newArray` reaches its slot through `this.allocateSlot()`, and
// `allocateSlot` is a public method. So a subclass that overrides it is the supported extension and
// **not one vendored byte changes** — `check-drift` still compares the whole tree against the anchor.

import { DomainSeparator } from '@aztec/constants';
import { poseidon2HashWithSeparator } from '@aztec/foundation/crypto/poseidon';
import type { Fq } from '@aztec/foundation/curves/bn254';
import { Fr } from '@aztec/foundation/curves/bn254';
import type { AztecAddress } from '@aztec/stdlib/aztec-address';
import type { CompleteAddress } from '@aztec/stdlib/contract';
import { computeLogTag } from '@aztec/stdlib/hash';
import { AppTaggingSecret, AppTaggingSecretKind, SiloedTag, Tag } from '@aztec/stdlib/logs';

import { EphemeralArrayService } from '../vendor/pxe/contract_function_simulator/ephemeral_array_service.ts';
import { ExecutionTaggingIndexCache } from '../vendor/pxe_notes/contract_function_simulator/execution_tagging_index_cache.ts';
import { separatorFromLabel } from './dev_keys.ts';

/** The label the ephemeral-slot separator is derived from. Read by the check, never re-typed. */
export const DEV_EPHEMERAL_SLOT_SEPARATOR_LABEL = 'codetracer-dev-wallet:ephemeral-array-slot:v1';

/** The ephemeral-slot separator. Computed from its label, the same discipline `dev_keys.ts` uses. */
export const DEV_EPHEMERAL_SLOT_SEPARATOR = separatorFromLabel(DEV_EPHEMERAL_SLOT_SEPARATOR_LABEL);

/**
 * `EphemeralArrayService` with a DETERMINISTIC slot allocator.
 *
 * Upstream draws a slot from `Fr.random()` and retries on collision, which is right for a wallet
 * that must not leak a correlatable slot and wrong for one whose recording has to replay. Here the
 * slot is `poseidon2(seed, counter)` under a derived separator, and the collision loop is KEPT —
 * with the allocated set tracked here rather than read out of the base class's private field, and
 * with a bound so a degenerate hash cannot spin forever.
 *
 * The base class's own `while (this.#arrays.has(...))` guard is unreachable from a subclass because
 * `#arrays` is a private field; the set below is the same guard over the same question, and
 * `allocatedSlots` makes it a thing a check can read rather than a claim.
 */
export class DeterministicEphemeralArrayService extends EphemeralArrayService {
  readonly #seed: Fr;
  readonly #issued = new Set<string>();
  #counter = 0;

  constructor(seed: Fr) {
    super();
    this.#seed = seed;
  }

  /** How many slots have been issued, so "no entropy was read" is auditable rather than asserted. */
  get allocatedSlots(): number {
    return this.#issued.size;
  }

  /**
   * ALLOCATION IS SYNCHRONOUS BECAUSE UPSTREAM'S IS. `newArray` calls `this.allocateSlot()` and uses
   * the result immediately, so an async override would return a `Promise` where a slot belongs and
   * the wire would serialise it as garbage. `poseidon2HashWithSeparator` is async, so the stream is
   * pre-derived: `prime(n)` fills a queue before execution and `allocateSlot` takes from it,
   * refusing BY NAME when it runs out rather than falling back to a random draw.
   */
  readonly #queue: Fr[] = [];

  /** Pre-derive `count` slots. Called before execution; nothing derives one during it. */
  async prime(count: number): Promise<void> {
    for (let i = 0; i < count; i++) {
      const slot = await poseidon2HashWithSeparator(
        [this.#seed, new Fr(BigInt(this.#counter++))],
        DEV_EPHEMERAL_SLOT_SEPARATOR,
      );
      if (this.#issued.has(slot.toString())) {
        // The collision branch upstream's loop exists for, kept rather than assumed away.
        continue;
      }
      this.#queue.push(slot);
    }
  }

  override allocateSlot(): Fr {
    const slot = this.#queue.shift();
    if (slot === undefined) {
      throw new Error(
        'DeterministicEphemeralArrayService: the pre-derived slot stream is exhausted. This service ' +
          'never falls back to Fr.random(), because a recording made through an ambient draw does not ' +
          'replay — see PRIVATE-EXECUTION.md section 5. Call prime(n) with a larger n.',
      );
    }
    this.#issued.add(slot.toString());
    return slot;
  }
}

/** One account this wallet holds, in the shape the tagging derivation needs. */
export interface TaggingAccount {
  readonly address: AztecAddress;
  readonly completeAddress: CompleteAddress;
  /** The master incoming viewing secret key, from upstream's own `deriveKeys`. */
  readonly ivsk: Fq;
}

/** What a resolved strategy looks like on the wire. Upstream's own union, from the vendored codec. */
export type ResolvedStrategy =
  | { type: 'non-interactive-handshake' }
  | { type: 'interactive-handshake' }
  | { type: 'unconstrained-secret'; secret: Fr };

/**
 * The wallet's tagging half.
 *
 * It holds the accounts, the per-secret index counters that a real PXE would keep in a
 * `SenderTaggingStore`, and the in-execution `ExecutionTaggingIndexCache` (vendored, RI-98) that
 * upstream uses to keep one execution's draws consistent with each other.
 */
export class DevTagging {
  readonly #accounts = new Map<string, TaggingAccount>();
  /** The persistent counter a `SenderTaggingStore` would hold, keyed by `AppTaggingSecret.toString()`. */
  readonly #lastUsedIndex = new Map<string, number>();
  /** Upstream's in-execution cache, so two draws in one frame agree. */
  readonly #executionCache = new ExecutionTaggingIndexCache();
  /** The sender `getSenderForTags` answers with, or `undefined` when the wallet has no default. */
  #senderForTags: AztecAddress | undefined;

  constructor(accounts: readonly TaggingAccount[], senderForTags?: AztecAddress) {
    for (const account of accounts) {
      this.#accounts.set(account.address.toString(), account);
    }
    this.#senderForTags = senderForTags;
  }

  /** The accounts this wallet can derive a tagging secret AS. */
  get accountCount(): number {
    return this.#accounts.size;
  }

  /** The default sender, or `undefined`. `getSenderForTags` maps this to `Option`. */
  senderForTags(): AztecAddress | undefined {
    return this.#senderForTags;
  }

  /** Set the default sender. Used by the demo and by the control arm. */
  setSenderForTags(sender: AztecAddress | undefined): void {
    this.#senderForTags = sender;
  }

  /** Whether the wallet holds this account — the question `getAppTaggingSecret` refuses on. */
  holds(address: AztecAddress): boolean {
    return this.#accounts.has(address.toString());
  }

  /**
   * Upstream's `getAppTaggingSecret`: the directional, app-siloed secret between two parties.
   *
   * Returns `undefined` when the wallet does not hold `sender`'s keys — which is `Option::none` on
   * the wire and is the honest answer, not a fabricated field. Upstream refuses the same case,
   * differently: it throws out of `getCompleteAddressOrFail`.
   */
  async appTaggingSecret(
    sender: AztecAddress,
    recipient: AztecAddress,
    app: AztecAddress,
    /**
     * THE DIRECTION, AND IT IS A SEPARATE PARAMETER BECAUSE THE TWO SIDES DISAGREE ABOUT IT.
     *
     * `computeUnconstrained(local, localIvsk, external, app, recipient)` takes the local party's
     * keys, the external party's address, and — separately — WHICH of the two the secret is directed
     * at. A SENDER deriving a secret for a recipient passes `recipient = external`, which is what
     * `aztec_prv_getAppTaggingSecret` wants. A RECIPIENT scanning for logs sent to it holds its own
     * keys locally and the SENDER's address externally, and the direction is still ITSELF.
     *
     * Defaulting it to `recipient` and leaving it there is right for the sender and wrong for the
     * recipient, and the two coincide exactly in the self-send case — which is the case the fixture
     * happens to exercise. So it is a parameter rather than a default that would be true of the one
     * measurement taken.
     */
    direction: AztecAddress = recipient,
  ): Promise<AppTaggingSecret | undefined> {
    const account = this.#accounts.get(sender.toString());
    if (!account) {
      return undefined;
    }
    return AppTaggingSecret.computeUnconstrained(account.completeAddress, account.ivsk, recipient, app, direction);
  }

  /**
   * Upstream's `getNextTaggingIndex`: the next index for a secret, RESERVED as it is handed out.
   *
   * THE RESERVATION IS THE POINT AND IT IS WHY THIS IS NOT A GETTER. Two sends to the same recipient
   * that both used index n would produce the same tag, and the recipient would see one log where two
   * were sent — the double-count the milestone's own control is about. The counter advances here,
   * and upstream's `ExecutionTaggingIndexCache` keeps the draws inside one execution consistent.
   */
  nextTaggingIndex(secret: AppTaggingSecret): number {
    const key = secret.toString();
    const inExecution = this.#executionCache.getLastUsedIndex(secret);
    const persisted = this.#lastUsedIndex.get(key);
    const last = inExecution ?? persisted;
    const next = last === undefined ? 0 : last + 1;
    this.#executionCache.setLastUsedIndex(secret, next);
    this.#lastUsedIndex.set(key, next);
    return next;
  }

  /**
   * THE RECIPIENT-SIDE PROBE START, WHICH IS A DIFFERENT NUMBER FROM THE SENDER-SIDE COUNTER AND
   * CONFLATING THEM COST A RUN.
   *
   * `nextTaggingIndex` is what a SENDER reserves; `getPendingTaggedLogsV2` is what a RECIPIENT
   * scans. A first version probed from `peekTaggingIndex`, so after the contract had reserved index
   * 0 the scan started at 1 and found **zero** logs over an index holding one — an absence produced
   * by the instrument rather than by the chain, which is this campaign's most expensive shape.
   *
   * Upstream keeps the two apart too: the sender's is in a `SenderTaggingStore` and the recipient's
   * in a `RecipientTaggingStore`, and `syncTaggedPrivateLogs` walks the second.
   */
  readonly #recipientSynced = new Map<string, number>();

  /** Where a recipient-side scan starts for this secret. Zero until something has been found. */
  recipientSyncedIndex(secret: AppTaggingSecret): number {
    return this.#recipientSynced.get(secret.toString()) ?? 0;
  }

  /** Advance the recipient-side scan past an index a log was found at. Monotonic. */
  advanceRecipientSyncedIndex(secret: AppTaggingSecret, foundAt: number): void {
    const key = secret.toString();
    const current = this.#recipientSynced.get(key) ?? 0;
    if (foundAt + 1 > current) {
      this.#recipientSynced.set(key, foundAt + 1);
    }
  }

  /** The index this secret would next hand out, without advancing it. For checks and controls. */
  peekTaggingIndex(secret: AppTaggingSecret): number {
    const last = this.#executionCache.getLastUsedIndex(secret) ?? this.#lastUsedIndex.get(secret.toString());
    return last === undefined ? 0 : last + 1;
  }

  /** The index ranges this execution used — upstream's own `getUsedTaggingIndexRanges`. */
  usedIndexRanges(): { extendedSecret: AppTaggingSecret; lowestIndex: number; highestIndex: number }[] {
    return this.#executionCache.getUsedTaggingIndexRanges() as never;
  }

  /**
   * Upstream's `resolveTaggingStrategy`, at this wallet's one supported strategy.
   *
   * `DEFAULT_TAGGING_SECRET_STRATEGY` upstream is `address-derived`, which resolves to an
   * `unconstrained-secret` computed from `getAppTaggingSecret`. The other two — a non-interactive
   * handshake against an on-chain registry, and an interactive one that goes back out through
   * `resolveCustomRequest` — need a HANDSHAKE REGISTRY CONTRACT and a custom-request resolver, and
   * this runtime has neither. **So they are refused by name rather than returned**: a resolved
   * strategy of `non-interactive-handshake` that no registry backs would send the contract to look
   * up a secret nobody published, which is a plausible default wearing a discriminant.
   *
   * A CONSTRAINED delivery mode is refused for the same reason, and it is refused by NAME: the
   * wire's `DELIVERY_MODE` maps `2` to `unconstrained` and `3` to `constrained`, and a constrained
   * secret comes from a handshake registry by definition.
   */
  async resolveTaggingStrategy(
    sender: AztecAddress,
    recipient: AztecAddress,
    app: AztecAddress,
    deliveryMode: AppTaggingSecretKind,
  ): Promise<ResolvedStrategy> {
    if (deliveryMode !== AppTaggingSecretKind.UNCONSTRAINED) {
      throw new Error(
        `resolveTaggingStrategy: delivery mode '${String(deliveryMode)}' asks for a CONSTRAINED tagging ` +
          'secret, which comes from an on-chain handshake registry. This wallet derives unconstrained, ' +
          'address-derived secrets from its own deterministic keys and has no registry to read, so it ' +
          'refuses by name rather than returning a handshake discriminant nothing backs.',
      );
    }
    const secret = await this.appTaggingSecret(sender, recipient, app);
    if (!secret) {
      throw new Error(
        `resolveTaggingStrategy: this wallet does not hold the keys of sender ${sender.toString()}, so it ` +
          'cannot derive an address-derived tagging secret for it. It holds ' +
          `${this.#accounts.size} account(s).`,
      );
    }
    return { type: 'unconstrained-secret', secret: secret.secret };
  }

  /**
   * The SILOED tag a (secret, index) pair produces — upstream's `Tag.compute` then
   * `SiloedTag.computeFromTagAndApp`.
   *
   * This is what the note database's tag index is keyed by, and it is what makes a discovery a
   * DISCOVERY: the wallet computes the tag it expects and looks for it, rather than being handed
   * one. A log tagged for another account produces a different secret and therefore a different
   * tag, and is not found — which is the control the milestone asks for.
   */
  async siloedTag(secret: AppTaggingSecret, index: number, app: AztecAddress): Promise<Fr> {
    // `SiloedTag.compute` AND NOT `Tag.compute` + `computeFromTagAndApp`, WHICH IS WHAT A FIRST
    // DRAFT DID AND IT WAS WRONG BY ONE HASH. Upstream's own `SiloedTag.compute` is THREE steps —
    // `Tag.compute`, then `computeLogTag(tag, UNCONSTRAINED_MSG_LOG_TAG | CONSTRAINED_MSG_LOG_TAG)`,
    // then the silo — and the middle one is a domain separation chosen by the secret's KIND. Skipping
    // it produces a perfectly well-formed field that no contract ever emits, so every tag lookup
    // would miss and "no logs found" would be a fact about this function rather than about the chain.
    // Read out of the pin's own `siloed_tag.js`, not remembered.
    //
    // `app` must equal `secret.app`, and it is passed separately only so a caller cannot silo with a
    // contract the secret was not derived for — which would also produce a tag nobody emits.
    if (!secret.app.equals(app)) {
      throw new Error(
        `DevTagging.siloedTag: the secret is app-siloed to ${secret.app.toString()} and the tag was ` +
          `asked to be siloed with ${app.toString()}. Two different contracts produce two different ` +
          'tags for the same pair of parties, which is the point of app-siloing.',
      );
    }
    const siloed = await SiloedTag.compute({ extendedSecret: secret, index });
    return siloed.value;
  }

  /**
   * The tag a CONTRACT emits, before the kernel silos it — `Tag.compute` then `computeLogTag`.
   *
   * This is the value `TestLog.emit_raw_private_log(tag, payload)` takes, and it is what makes a
   * discovery a discovery: the wallet computes the tag, a REAL CIRCUIT emits it, the block sealer
   * silos it the way a kernel would, and the wallet then computes the SILOED tag independently and
   * looks for it. Two producers, one value — the shape `DEV-WALLET.md` §4 already uses for
   * `returnsHash`.
   */
  async emittedTag(secret: AppTaggingSecret, index: number): Promise<Fr> {
    const tag = await Tag.compute({ extendedSecret: secret, index });
    const separator =
      secret.kind === AppTaggingSecretKind.CONSTRAINED
        ? DomainSeparator.CONSTRAINED_MSG_LOG_TAG
        : DomainSeparator.UNCONSTRAINED_MSG_LOG_TAG;
    return computeLogTag(tag.value, separator);
  }
}
