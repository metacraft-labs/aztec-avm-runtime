// The wallet demo page: `transfer_in_public` from a wallet handshake to a settled block to a `.ct`.
//
// ===========================================================================================
// IT IS BOTH THE DEMO AND THE HARNESS, WHICH IS M27's CONVENTION AND ITS REASON IS UNCHANGED.
// ===========================================================================================
//
// Everything `tools/run_wallet_transfer_arms.mjs` drives is a function on `window.walletDemo`, and
// every one of them is also a button. There is no test-only path into the runtime or into the
// wallet, so "the demo works" and "the checks pass" cannot come apart.
//
// ===========================================================================================
// THE ONE THING THIS PAGE PROVES THAT NOTHING ELSE DOES.
// ===========================================================================================
//
// M33's review established, by planting `const _nodeOnlyProbe = setImmediate;`, that a metafile
// records IMPORTS and a free identifier is not one — so every browser-shape check in the repository
// was green over a `wallet.js` that died on the first line a page evaluated. It closed that with a
// probe page that IMPORTS the bundle. **This page goes one step further: it RUNS the wallet.** The
// handshake, the ECDH, the AES-GCM session, the deterministic key derivation, the vendored
// transaction builder and the AVM all execute in Chromium, in one page, and the `.ct` the page
// produces is read back by the pinned reader.
//
// That distinction is the milestone's own instruction and it is worth keeping in the file: the
// wallet must be *loaded and exercised* in a browser, not *asserted to be browser-shaped*.
//
// ===========================================================================================
// THE DEV SHORTCUTS ARE NODE-SIDE, THEY ARE LABELLED, AND THEY ARE NOT THE WALLET'S.
// ===========================================================================================
//
// Three things this page does directly against the resident world state, and each is a `DEV
// SHORTCUT` in the log where a person will see it: the contract-address nullifier, the public
// initialization nullifier, and a token balance for the sender. M29 found all three by looking at
// the executed step stream, and `token_transfer.ts` carries the full account of why each one is
// needed. They are the NODE's business — seeding a chain nobody mined — and a wallet has no way to
// do them and no business doing them. The milestone's fourth deliverable is about
// `registerContract`, which is a wallet's business and does go through the wallet here.
//
// FEE JUICE IS THE FOURTH, and it is M20's recorded DD-2 shortcut, unchanged.

import {
  DateProvider,
  fetchCtWriter,
  openAvmRuntime,
  recordAndDownload,
  getContractFunctionAbi,
  getFunctionSelector,
  runTokenTransfer,
  storageSlotOf,
  type OpenedRuntime,
} from '../src/entry_testing.ts';
import {
  DEFAULT_DEV_WALLET_SEED,
  DEV_WALLET_METHODS,
  DEV_WALLET_NAME,
  DEV_WALLET_REFUSAL_REASONS,
  DEV_WALLET_REFUSED,
  DEV_WALLET_SERVED,
  DEV_WALLET_VERSION,
  PortConnectionHandler,
  PortWalletProvider,
  WALLET_DECISION_METADATA,
  WALLET_SEED_METADATA,
  createDevWallet,
  deriveDevAccounts,
  renderWalletDecision,
  type DevWalletHandle,
  type DevWalletHost,
} from '../src/entry_wallet.ts';

import { Fr } from '@aztec/foundation/curves/bn254';
import { poseidon2HashWithSeparator } from '@aztec/foundation/crypto/poseidon';
import { CONTRACT_INSTANCE_REGISTRY_CONTRACT_ADDRESS, DomainSeparator } from '@aztec/constants';
import { AztecAddress } from '@aztec/stdlib/aztec-address';
// STATIC, NOT DYNAMIC, and the reason is a build failure rather than a preference: the first draft
// reached these two through `await import(…)` inside a helper, esbuild split each one into a chunk
// of its own (`chunks/abi-*.js`, `chunks/tests-*.js`), and the build refused them because no budget
// covers them — which is `chunk-budgets.json`'s no-catch-all rule doing exactly its job. A page's
// eager set is a decision; a lazily-split chunk nobody declared is not.
import { FunctionCall, FunctionType, encodeArguments, loadContractArtifact } from '@aztec/stdlib/abi';
import { computeInitializationHash } from '@aztec/stdlib/contract';
import { computePublicDataTreeLeafSlot, deriveStorageSlotInMap, siloNullifier } from '@aztec/stdlib/hash';
import { PublicKeys } from '@aztec/stdlib/keys';
import { makeContractClassPublic, makeContractInstanceFromClassId } from '@aztec/stdlib/testing';
import { ExecutionPayload } from '@aztec/stdlib/tx';

const MODULE_URL = './assets/avm.wasm';
const CT_WRITER_URL = './assets/ct_writer.wasm';
const ARTIFACT_URL = './assets/token_contract-Token.json';

/** A UUID. `ct-print` refuses a `recording_id` that is not exactly 36 characters. */
const RECORDING_ID = '01949fcc-7d92-7e9c-8000-000000003401';

/** The application identifier the session is bound to. */
const APP_ID = 'm34-wallet-demo';

/** The public function the demo calls, and the read beside it. Same pair as M27's demo. */
const TRANSFER_FUNCTION = 'transfer_in_public';
const BALANCE_FUNCTION = 'balance_of_public';

const DEMO_FUNDING = new Fr(10n ** 12n);
const DEMO_TOKEN_BALANCE = 1_000n;
const DEMO_TRANSFER_AMOUNT = 5n;

const log: string[] = [];
function say(line: string): void {
  log.push(line);
  const el = document.getElementById('log');
  if (el) el.textContent = log.join('\n');
}

/**
 * A JSON-safe copy of an arm's report.
 *
 * `Runtime.evaluate` with `returnByValue` refuses anything V8 cannot serialise and says only
 * `Object couldn't be returned by value` — no path, no field. This page produced exactly that the
 * first time `sendTx` succeeded, because upstream's `TxHash` codec returns a class instance. Doing
 * the conversion HERE, with a `bigint` replacer, turns "the arm returned nothing" into a report a
 * check can read, and keeps every number a check compares a STRING rather than a float.
 */
function jsonSafe<T>(value: T): T {
  return JSON.parse(JSON.stringify(value, (_k, v) => (typeof v === 'bigint' ? v.toString() : v))) as T;
}

let opened: OpenedRuntime | null = null;
let artifact: unknown = null;
let lastRun: Record<string, unknown> | null = null;
let lastWallet: DevWalletHandle | null = null;

async function open(): Promise<OpenedRuntime> {
  if (opened) return opened;
  opened = await openAvmRuntime({
    moduleUrl: MODULE_URL,
    clock: new DateProvider(),
    production: { intervalMs: 0, minBlockSpacingSeconds: 1 } as never,
    // The page records, so it drives M9's observation hook.
    collectExecutionSteps: true,
    disclosureSink: (line: string) => say(`[disclosure] ${line}`),
  });
  say(`avm.wasm: ${opened.compiled.byteLength} bytes, ${opened.reactor.exportNames.length} exports`);
  return opened;
}

async function loadArtifact(): Promise<unknown> {
  if (artifact) return artifact;
  const response = await fetch(ARTIFACT_URL);
  if (!response.ok) throw new Error(`${ARTIFACT_URL}: ${response.status}`);
  artifact = await response.json();
  return artifact;
}

/**
 * The node side of the seam, over an `OpenedRuntime`.
 *
 * FOUR METHODS AND NO MORE, which is the measurement the seam is for: everything else a wallet
 * needs, it derives or remembers itself. `DevWalletHost` is an interface rather than an import so
 * that `wallet.js` does not reach the runtime and `browser.js` does not reach the wallet — the two
 * DD-11 directions M33's separate entry point exists to keep apart.
 */
function hostOver(o: OpenedRuntime): DevWalletHost {
  return {
    chainInfo: async () => ({ chainId: new Fr(1), version: new Fr(1) }),
    registerContractClass: async (contractClass) =>
      (await o.runtime.registerContract(contractClass as never, null)).classes,
    registerContractInstance: async (instance) =>
      (await o.runtime.registerContract(null, instance as never)).instances,
    // BOTH ANSWERS COME OUT OF THE NODE'S NULLIFIER TREE, which is where the AVM itself looks.
    // M29's finding is what makes this the right question rather than a bookkeeping one: an address
    // is CALLABLE when its contract-address nullifier is in the tree, and a `#[public]` function of
    // a contract with an initializer asserts its public initialization nullifier is there too. So
    // `isPublished` and `isInitialized` are two lookups and neither is a fact the caller supplies —
    // which is why `getContractMetadata` answers differently before and after the dev shortcuts run,
    // and why the arm asks it on both sides of them.
    isPublished: async (address: AztecAddress) =>
      o.publicDataTree.nullifierExists(
        await siloNullifier(
          await AztecAddress.fromNumber(CONTRACT_INSTANCE_REGISTRY_CONTRACT_ADDRESS),
          address.toField(),
        ),
      ),
    isInitialized: async (address: AztecAddress) => {
      const publicInit = await poseidon2HashWithSeparator(
        [address.toField()],
        DomainSeparator.PUBLIC_INITIALIZATION_NULLIFIER,
      );
      return o.publicDataTree.nullifierExists(await siloNullifier(address, publicInit));
    },
    submitPublicTx: async (tx) => {
      const receipt = await o.runtime.submitExternal(tx as never);
      return { txHash: receipt.txHash };
    },
  };
}

/** A live wallet connection: the proxy the runtime holds and the wallet on the far side. */
interface Connected {
  /** The wallet proxy the runtime talks to — every call crosses the encrypted session. */
  readonly proxy: Record<string, (...a: unknown[]) => Promise<unknown>>;
  /** The wallet itself, on the far side. */
  readonly handle: DevWalletHandle;
  /** The provider, for the disclosure and the disconnect. */
  readonly provider: PortWalletProvider;
  /** The handler, for what it recorded about the app. */
  readonly handler: PortConnectionHandler;
  /** The verification hash both ends computed independently. */
  readonly verificationHash: string;
  /** The wallet id discovery returned. */
  readonly walletId: string;
}

async function attachWallet(
  o: OpenedRuntime,
  options: { seed?: string; decline?: string; suppress?: readonly string[] } = {},
): Promise<Connected> {
  const handle = await createDevWallet({
    host: hostOver(o),
    seed: options.seed ?? DEFAULT_DEV_WALLET_SEED,
    accounts: 2,
    ...(options.decline !== undefined ? { declineAuthorization: options.decline } : {}),
    ...(options.suppress !== undefined ? { suppressDecisions: options.suppress } : {}),
  });
  const { port1, port2 } = new MessageChannel();
  const handler = new PortConnectionHandler(
    port2,
    {
      walletId: 'codetracer-dev-wallet',
      walletName: DEV_WALLET_NAME,
      walletVersion: DEV_WALLET_VERSION,
      autoApproveDiscovery: true,
    },
    { getWallet: () => handle.wallet },
  );
  handler.start();
  const provider = new PortWalletProvider(port1, { chainInfo: { chainId: 1, version: 1 } });
  const pending = await provider.connect(APP_ID);
  const proxy = pending.confirm() as unknown as Record<string, (...a: unknown[]) => Promise<unknown>>;
  // §8.4 crosses first, before any capability is asked for. M33's machinery, unchanged.
  const disclosed = await provider.discloseToWallet();
  say(`[wallet] connected to ${pending.walletInfo.name} (${pending.walletInfo.id})`);
  say(`[wallet] verification hash ${pending.verificationHash}`);
  say(`[wallet] disclosure ${JSON.stringify(disclosed).slice(0, 96)}…`);
  lastWallet = handle;
  return {
    proxy,
    handle,
    provider,
    handler,
    verificationHash: pending.verificationHash,
    walletId: pending.walletInfo.id,
  };
}


/**
 * One call across the encrypted session, with the METHOD NAME attached to any failure.
 *
 * Upstream's own return codec runs on this side of the boundary, so a wallet answering the wrong
 * SHAPE fails inside `parseAsync` with a `ZodError` that names the field and not the method. The
 * first run of this page produced exactly that: two union issues at an empty path, from one of nine
 * calls, with nothing saying which. A failure that cannot name its subject is the thing this
 * campaign spends most of its rules on.
 */
async function callWallet(
  c: Connected,
  method: string,
  ...args: unknown[]
): Promise<unknown> {
  try {
    return await c.proxy[method]!(...args);
  } catch (e) {
    const err = e as Error;
    throw new Error(`wallet.${method} failed: ${err.name}: ${err.message}`, { cause: e });
  }
}

/**
 * ARM: the whole thing. A wallet handshake, a registration through the wallet, a transfer built by
 * the wallet, a settled block.
 */
async function armWalletTransfer(options: { seed?: string; decline?: string; suppress?: readonly string[] } = {}):
  Promise<Record<string, unknown>> {
  const o = await open();
  const raw = await loadArtifact();
  const parsed = loadContractArtifact(raw as never);
  const c = await attachWallet(o, options);

  // ---- what the wallet says about itself, over the wire ---------------------------------------
  const accounts = (await callWallet(c, 'getAccounts')) as { alias: string; item: AztecAddress }[];
  const chainInfo = (await callWallet(c, 'getChainInfo')) as { chainId: Fr; version: Fr };
  const sender = accounts[0]!.item;
  const recipient = accounts[1]!.item;
  await callWallet(c, 'registerSender', recipient, 'demo-recipient');
  const addressBook = (await callWallet(c, 'getAddressBook')) as { alias: string; item: AztecAddress }[];
  say(`[wallet] accounts ${accounts.map(a => a.item.toString()).join(', ')}`);

  // ---- DELIVERABLE 4: registration through the wallet ------------------------------------------
  await callWallet(c, 'registerContractClass', parsed);
  const contractClassId = await classIdOf(parsed);
  const deployer = await AztecAddress.fromNumber(4242);
  // THE SAME LOOKUP `token_transfer.ts` USES, so the two routes derive the same class AND the same
  // address — which is what makes `test_deployment_through_wallet`'s comparison a comparison.
  const constructorAbi = getContractFunctionAbi('constructor', parsed);
  const initializationHash = await computeInitializationHash(constructorAbi as never, [deployer, 'Tok', 'TOK', 18]);
  const instance = await makeContractInstanceFromClassId(contractClassId, 27, {
    deployer,
    initializationHash,
    immutablesHash: new Fr(28),
    publicKeys: PublicKeys.default(),
  });
  await callWallet(c, 'registerContract', instance);
  say(`[wallet] registered ${parsed.name} at ${instance.address.toString()}`);

  // ASKED BEFORE THE DEV SHORTCUTS RUN. Both fields the wallet answers here come out of the node's
  // NULLIFIER TREE, so this reading is the one where the contract is registered and not yet
  // callable — and the reading after the shortcuts is the other answer. Two readings of one
  // instrument, so "published" is a measurement rather than a constant.
  const metadataBefore = (await callWallet(c, 'getContractMetadata', instance.address)) as Record<string, unknown>;
  const classMetadata = (await callWallet(c, 'getContractClassMetadata', contractClassId)) as Record<string, unknown>;
  // THE CONTROL FOR THAT LOOKUP: an id the wallet has never seen must answer the other way.
  const unknownClassMetadata = (await callWallet(c, 'getContractClassMetadata', new Fr(999_331n))) as Record<string, unknown>;

  // ---- DEV SHORTCUTS, node-side and labelled ---------------------------------------------------
  const deploymentNullifier = await siloNullifier(
    await AztecAddress.fromNumber(CONTRACT_INSTANCE_REGISTRY_CONTRACT_ADDRESS),
    instance.address.toField(),
  );
  o.publicDataTree.insertNullifier(deploymentNullifier);
  say('[DEV SHORTCUT] inserted the contract-address nullifier directly into the nullifier tree');

  const publicInit = await poseidon2HashWithSeparator(
    [instance.address.toField()],
    DomainSeparator.PUBLIC_INITIALIZATION_NULLIFIER,
  );
  const initializationNullifier = await siloNullifier(instance.address, publicInit);
  o.publicDataTree.insertNullifier(initializationNullifier);
  say('[DEV SHORTCUT] inserted the public initialization nullifier directly');

  const publicBalancesSlot = storageSlotOf(raw, 'public_balances');
  const senderBalanceSlot = await deriveStorageSlotInMap(publicBalancesSlot, sender);
  const senderBalanceLeaf = await computePublicDataTreeLeafSlot(instance.address, senderBalanceSlot);
  o.publicDataTree.insertPublicDataLeaf(senderBalanceLeaf, new Fr(DEMO_TOKEN_BALANCE));
  say('[DEV SHORTCUT] credited the sender a token balance directly in the public data tree');

  const fundedLeafSlot = await o.runtime.fundFeeJuice(sender, DEMO_FUNDING);
  say('[DEV SHORTCUT] credited fee juice directly (M20, DD-2)');

  // THE SECOND READING. Same call, same wallet, same instrument, after the two nullifiers landed.
  const metadataAfter = (await callWallet(c, 'getContractMetadata', instance.address)) as Record<string, unknown>;

  // ---- DELIVERABLE 3: the transaction, built by the wallet -------------------------------------
  //
  // The dApp says which functions to call. The WALLET derives each selector from the artifact it
  // holds, compares it with the one declared here, refuses on a disagreement, and builds the
  // calldata with M26's vendored builder. So the selector the AVM receives is the wallet's
  // derivation and not this page's.
  const payload = new ExecutionPayload(
    [
      await callOf(parsed, instance.address, TRANSFER_FUNCTION, [sender, recipient, DEMO_TRANSFER_AMOUNT, new Fr(0)], false),
      // STATIC, because `balance_of_public` is `#[view]` and aztec-nr's generated dispatch asserts
      // it. M29's finding, and it is the same call pair the direct demo makes.
      await callOf(parsed, instance.address, BALANCE_FUNCTION, [sender], true),
    ],
    [],
    [],
    [],
    sender,
  );

  const sendOutcome = await callWallet(c, 'sendTx', payload, { from: sender })
    .then(v => ({ sent: v as Record<string, unknown> }), e => ({ refused: { name: String(((e as Error).cause as Error | undefined)?.name ?? (e as Error).name), message: String((e as Error).message) } }));

  let blockNumber: number | null = null;
  let outcome: string | null = null;
  let revertCode: number | null = null;
  let blockTxHashes: string[] = [];
  if ('sent' in sendOutcome) {
    const block = await o.runtime.produceBlock();
    const txHash = String(sendOutcome.sent.txHash);
    const settled = o.runtime.receiptFor(txHash);
    blockNumber = settled.blockNumber;
    outcome = typeof settled.outcome === 'string'
      ? settled.outcome
      : String((settled.outcome as { kind?: string } | null)?.kind ?? JSON.stringify(settled.outcome));
    blockTxHashes = block ? [...block.txHashes] : [];
    const processed = (
      (block as never as { processed?: readonly {
        hash: { toString(): string };
        revertCode: { getCode(): number; getDescription(): string };
      }[] } | null)?.processed ?? []
    ).find(p => p.hash.toString() === txHash);
    revertCode = processed === undefined ? null : processed.revertCode.getCode();
    say(`[wallet] ${parsed.name}.${TRANSFER_FUNCTION} -> ${outcome} in block ${blockNumber}, revertCode ${revertCode}`);
  } else {
    say(`[wallet] the wallet refused: ${sendOutcome.refused.name}`);
  }

  const executed = o.steps.last;
  const decisions = c.handle.decisions();
  const report = {
    seed: c.handle.seed,
    walletId: c.walletId,
    walletName: DEV_WALLET_NAME,
    verificationHash: c.verificationHash,
    served: [...DEV_WALLET_SERVED],
    refusedNames: [...DEV_WALLET_REFUSED],
    accounts: accounts.map(a => ({ alias: a.alias, address: a.item.toString() })),
    chainInfo: { chainId: chainInfo.chainId.toString(), version: chainInfo.version.toString() },
    addressBook: addressBook.map(a => ({ alias: a.alias, address: a.item.toString() })),
    contractAddress: instance.address.toString(),
    contractClassId: contractClassId.toString(),
    artifactName: parsed.name,
    metadataBefore: {
      isContractPublished: metadataBefore.isContractPublished,
      initializationStatus: metadataBefore.initializationStatus,
      hasInstance: metadataBefore.instance !== undefined && metadataBefore.instance !== null,
    },
    metadataAfter: {
      isContractPublished: metadataAfter.isContractPublished,
      initializationStatus: metadataAfter.initializationStatus,
      hasInstance: metadataAfter.instance !== undefined && metadataAfter.instance !== null,
    },
    classMetadata,
    unknownClassMetadata,
    deploymentNullifier: deploymentNullifier.toString(),
    initializationNullifier: initializationNullifier.toString(),
    fundedLeafSlot: fundedLeafSlot.toString(),
    send: sendOutcome,
    blockNumber,
    outcome,
    revertCode,
    blockTxHashes,
    executedSteps: executed === null ? 0 : executed.steps.length,
    instructionsExecuted: executed?.instructionsExecuted ?? null,
    contexts: executed === null ? 0 : new Set(executed.steps.map(s => s.contextId)).size,
    decisions: decisions.map(d => ({ ...d })),
    decisionMethods: decisions.map(d => d.method),
    decisionKinds: decisions.map(d => d.decision),
    walletSideDisclosure: c.handler.disclosure(),
    handlerRefusals: c.handler.refusals(),
    providerRefusals: c.provider.refusals(),
    // Both crypto counters, so the page's own DD-11 story is a number rather than an absence.
    poseidonCallsTotal: o.poseidon.calls,
    grumpkinCallsTotal: o.grumpkin.calls,
  };
  lastRun = jsonSafe(report);
  return lastRun;
}

/**
 * ARM: every method the wallet does not serve refuses BY NAME, and a served one reaches through.
 *
 * TWO ROUTES, AND THE SPLIT IS NOT COSMETIC. Called across the encrypted session with the wrong
 * ARITY, a refused method never reaches the wallet at all: upstream's own `parseWithOptionals`
 * rejects the arguments first and the caller gets a `too_small` zod error naming no method. The
 * first run of this arm measured exactly that, and it would have been a green "every method
 * refuses" over six refusals none of which the wallet issued.
 *
 * So the DIRECT route calls each one on the wallet object itself, where the refusal is the wallet's
 * `DevWalletRefused` naming the method and its reason; and the WIRE route sends one refused method
 * with arguments that DO satisfy upstream's codec, so at least one refusal is shown to survive the
 * whole encrypted round trip. The positive control is a SERVED method on the same object over the
 * same session.
 */
async function armRefusals(): Promise<Record<string, unknown>> {
  const o = await open();
  const c = await attachWallet(o);
  const direct: Record<string, unknown> = {};
  const w = c.handle.wallet as unknown as Record<string, (...a: unknown[]) => Promise<unknown>>;
  for (const name of DEV_WALLET_REFUSED) {
    direct[name] = await Promise.resolve()
      .then(() => w[name]!())
      .then(v => ({ resolved: v === undefined ? 'undefined' : JSON.stringify(v) }),
        e => ({ rejected: { name: String((e as Error).name), message: String((e as Error).message) } }));
  }
  // OVER THE WIRE, with arguments upstream's codec accepts: an empty `ExecutionPayload` and a
  // `SimulateOptions` naming a `from`. The refusal has to cross the AES-GCM session and come back.
  const accounts = (await callWallet(c, 'getAccounts')) as { item: AztecAddress }[];
  const overWire = await Promise.resolve()
    .then(() => c.proxy.simulateTx!(new ExecutionPayload([], [], [], [], undefined), { from: accounts[0]!.item }))
    .then(v => ({ resolved: JSON.stringify(v) }),
      e => ({ rejected: { name: String((e as Error).name), message: String((e as Error).message) } }));
  // THE CONTROL: a SERVED method, on the same object, across the same encrypted boundary.
  const servedControl = await Promise.resolve()
    .then(() => c.proxy.getChainInfo!())
    .then(v => ({ resolved: JSON.stringify(v) }), e => ({ rejected: String((e as Error).message) }));
  return jsonSafe({
    refused: [...DEV_WALLET_REFUSED],
    served: [...DEV_WALLET_SERVED],
    methods: [...DEV_WALLET_METHODS],
    reasons: { ...DEV_WALLET_REFUSAL_REASONS },
    direct,
    overWire,
    servedControl,
    decisionKinds: c.handle.decisions().map(d => d.decision),
  });
}

/** ARM: the deterministic keys, derived in this page, three times. */
async function armDeterministicKeys(): Promise<Record<string, unknown>> {
  await open();
  const first = await deriveDevAccounts(DEFAULT_DEV_WALLET_SEED, 3);
  const second = await deriveDevAccounts(DEFAULT_DEV_WALLET_SEED, 3);
  const other = await deriveDevAccounts('0x00000000000000000000000000000000000000000000000000000000deadbeef', 3);
  const render = (a: typeof first) => a.map(x => ({
    index: x.index,
    secret: x.secret.toString(),
    partialAddress: x.partialAddress.toString(),
    publicKeysHash: x.publicKeysHash.toString(),
    address: x.address.toString(),
  }));
  return jsonSafe({
    seed: DEFAULT_DEV_WALLET_SEED,
    otherSeed: '0x00000000000000000000000000000000000000000000000000000000deadbeef',
    first: render(first),
    second: render(second),
    other: render(other),
  });
}

/** ARM: the `.ct` container, with the wallet's decisions in it as trace records. */
async function armRecord(options: { download?: boolean } = {}): Promise<Record<string, unknown>> {
  const run = lastRun ?? (await armWalletTransfer());
  const o = await open();
  const handle = lastWallet;
  if (handle === null) throw new Error('no wallet has been attached');
  const writerBytes = await fetchCtWriter(CT_WRITER_URL);
  const decisions = handle.decisions();
  const recording = await recordAndDownload({
    writerBytes,
    rawArtifact: await loadArtifact(),
    contractAddress: AztecAddress.fromString(String(run.contractAddress)).toBuffer(),
    frameNames: [`Token.${TRANSFER_FUNCTION}`, `Token.${BALANCE_FUNCTION}`],
    recordingId: RECORDING_ID,
    executed: o.steps.last,
    download: options.download !== false,
    filename: `aztec-avm-wallet-${RECORDING_ID}.ct`,
    // DELIVERABLE 5. The seed first, then one record per decision, in the wallet's own order.
    extraLogEvents: [
      { metadata: WALLET_SEED_METADATA, content: `seed=${handle.seed} accounts=${handle.accounts().length}` },
      ...decisions.map(d => ({ metadata: WALLET_DECISION_METADATA, content: renderWalletDecision(d) })),
    ],
  });
  say(`[wallet] wrote ${recording.bytes} bytes, ${recording.logEvents} log event(s)`);
  return jsonSafe({
    ...recording,
    container: undefined,
    containerBytes: recording.bytes,
    decisionsWritten: decisions.length,
    seedRecord: `seed=${handle.seed} accounts=${handle.accounts().length}`,
    decisionRecords: decisions.map(renderWalletDecision),
  });
}

/**
 * ARM: the direct shortcut, still working and still labelled.
 *
 * `runTokenTransfer` is M27's path and it writes the resident store directly. It is NOT deleted and
 * it is NOT a silent alternative: the milestone's fourth deliverable says the shortcut survives as
 * an explicitly-named one, and this arm is where it is named. It runs in a runtime of its own so
 * the two paths do not share a world state — a comparison between two routes that had already
 * written each other's state would say nothing.
 */
async function armDirectShortcut(): Promise<Record<string, unknown>> {
  const raw = await loadArtifact();
  const o = await openAvmRuntime({
    moduleUrl: MODULE_URL,
    clock: new DateProvider(),
    production: { intervalMs: 0, minBlockSpacingSeconds: 1 } as never,
    collectExecutionSteps: true,
    disclosureSink: () => {},
  });
  try {
    const report = await runTokenTransfer(o, raw);
    say(`[DEV SHORTCUT] the direct path still works: ${report.outcome}, revertCode ${report.revertCode}`);
    return jsonSafe({
      label: 'DEV SHORTCUT — the direct store write, kept and named',
      contractAddress: report.contractAddress,
      contractClassId: report.contractClassId,
      outcome: report.outcome,
      revertCode: report.revertCode,
      registeredClasses: report.registeredClasses,
      registeredInstances: report.registeredInstances,
    });
  } finally {
    await o.close();
  }
}

/** The class id the wallet derives, derived here too so the two can be compared. */
async function classIdOf(parsed: { name: string; functions: { name: string; bytecode: string }[] }): Promise<Fr> {
  const dispatch = parsed.functions.find(f => f.name === 'public_dispatch');
  if (!dispatch) throw new Error('the artifact has no public_dispatch');
  const cls = await makeContractClassPublic(27, dispatch.bytecode as never);
  return cls.id;
}

/**
 * One `FunctionCall`, with the selector derived from the ABI — as the dApp declares it.
 *
 * THROUGH THE VENDORED HELPERS AND NOT THROUGH `artifact.functions`. `transfer_in_public` is not in
 * `functions` at all: a `#[public]` function of a contract with a `public_dispatch` lives in
 * `nonDispatchPublicFunctions`, and `getContractFunctionAbi` is upstream's own two-place lookup.
 * The first run of this page failed with "the artifact has no transfer_in_public" over an artifact
 * that has it — which is the campaign's "an absence claim is only as wide as the places you
 * looked", in a demo rather than in a check.
 *
 * The selector the WALLET derives is the one that reaches the AVM; this one is the caller's
 * DECLARATION, and the wallet compares the two and refuses on a disagreement.
 */
async function callOf(
  parsed: Parameters<typeof getContractFunctionAbi>[1],
  to: AztecAddress,
  name: string,
  args: unknown[],
  isStatic: boolean,
): Promise<FunctionCall> {
  const abi = getContractFunctionAbi(name, parsed);
  if (!abi) throw new Error(`the artifact has no ${name}`);
  const selector = await getFunctionSelector(name, parsed);
  return new FunctionCall(
    name,
    to,
    selector,
    FunctionType.PUBLIC,
    false,
    isStatic,
    encodeArguments(abi as never, args),
    // THE ARTIFACT'S OWN `returnTypes`, AND IT IS REQUIRED AT THE INSTALLED PIN.
    //
    // A second anchor-versus-pin divergence, measured the same way as `registerContract`'s: the
    // `cpp` anchor's `FunctionCall` carries a singular `returnType` with a back-compat transform
    // that accepts either spelling, and the PUBLISHED `@aztec/stdlib@5.0.0-nightly.20260626` — the
    // one this repository depends on — declares `returnTypes: z.array(AbiTypeSchema)`, not
    // optional. Passing `undefined` fails the payload's own codec on the way across the encrypted
    // session, at `path: [0, "calls", 0, "returnTypes"]`. `DEV-WALLET.md` section 5 records both.
    (abi as { returnTypes?: unknown[] }).returnTypes ?? [],
  );
}

const api = {
  armWalletTransfer,
  armRefusals,
  armDeterministicKeys,
  armRecord,
  armDirectShortcut,
  status: () => ({
    opened: opened !== null,
    seed: lastWallet?.seed ?? null,
    decisions: lastWallet ? lastWallet.decisions().length : 0,
    log: [...log],
  }),
};

declare global {
  // eslint-disable-next-line no-var
  var walletDemo: typeof api;
  // eslint-disable-next-line no-var
  var walletDemoReady: boolean;
}

globalThis.walletDemo = api;
globalThis.walletDemoReady = true;
say('wallet demo ready');

for (const [id, fn] of Object.entries({
  'btn-wallet-transfer': () => armWalletTransfer(),
  'btn-wallet-record': () => armRecord(),
  'btn-wallet-decline': () => armWalletTransfer({ decline: 'the operator declined this transaction' }),
})) {
  document.getElementById(id)?.addEventListener('click', () => {
    (fn as () => Promise<unknown>)().catch((e: unknown) => say(`ERROR ${String(e)}`));
  });
}
