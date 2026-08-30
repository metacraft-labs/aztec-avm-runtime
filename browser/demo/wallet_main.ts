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
  EPHEMERAL_RETURN_ORACLES,
  ORACLE_EPHEMERAL_RETURN_LABELS,
  ORACLE_ENVIRONMENT_VERSION,
  ORACLE_IMPLEMENTED,
  ORACLE_NAMES,
  ORACLE_REFUSAL_REASONS,
  ORACLE_REFUSING,
  assertOracleSurfaceMatchesDeclaration,
  createDevWallet,
  createPrivateOracleHandler,
  deriveDevAccounts,
  executePrivateFunction,
  initPrivateExecution,
  oracleMethodName,
  privateExecutionAssets,
  renderWalletDecision,
  toAddressValue,
  toFieldValue,
  type DevWalletHandle,
  type DevWalletHost,
} from '../src/entry_wallet.ts';

import { buildACIRCallback } from '../src/vendor/pxe/contract_function_simulator/oracle/acir_callback.ts';
import { Fr } from '@aztec/foundation/curves/bn254';
import { poseidon2HashWithSeparator } from '@aztec/foundation/crypto/poseidon';
import {
  CONTRACT_INSTANCE_REGISTRY_CONTRACT_ADDRESS,
  DomainSeparator,
  MAX_FR_CALLDATA_TO_ALL_ENQUEUED_CALLS,
} from '@aztec/constants';
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

// M35: private execution. Four assets, and none of them is fetched by a page that never asks for a
// private execution — which is DD-11's own rule and is asserted on the browser's network log.
const ACVM_WASM_URL = './assets/acvm_js_bg.wasm';
const NOIRC_ABI_WASM_URL = './assets/noirc_abi_wasm_bg.wasm';
const ORACLE_CHECK_ARTIFACT_URL = './assets/oracle_version_check_contract-OracleVersionCheck.json';
// A SECOND CONTRACT, and it is here for the ladder rather than for variety: the milestone's claim is
// that Token.transfer, Token.mint_to_private and PrivateVoting.cast_vote ALL stop at the same oracle.
// Two of those three live in the Token artifact already; the third needs its own.
const VOTING_ARTIFACT_URL = './assets/private_voting_contract-PrivateVoting.json';

/** The dev chain's own ids, so a private frame is this chain's rather than a fabricated one. */
const PRIVATE_CHAIN_ID = 1n;
const PRIVATE_CHAIN_VERSION = 1n;
/** The entropy seed for a private frame. An ARGUMENT, never generated. */
const PRIVATE_ENTROPY_SEED = 0x35n;

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
    // THE DIRECT PATH'S OWN STEP COUNT, READ OUT OF ITS OWN RUNTIME.
    //
    // ADDED BY M34's REVIEW, AND THE REASON IS THE MILESTONE'S HEADLINE. `DEV-WALLET.md` §4 says
    // "the step count is M27's and M29's direct-path figure to the step, which is the interesting
    // part: the wallet route and the back-door route execute the same program" — and nothing
    // asserted it. The LEFT side (the wallet route's 516) was re-derived from this arm report; the
    // RIGHT side was a sentence about a number measured in another milestone's arm run, which is
    // `CAMPAIGN-BRIEF.md`'s "a figure nobody re-derives rots" exactly. The direct path runs HERE, in
    // this same browser session, in a runtime of its own — so the right-hand number costs two
    // fields, and `test_deployment_through_wallet` §5 asserts the identity with the non-degeneracy
    // floor beside it.
    const executed = o.steps.last;
    return jsonSafe({
      label: 'DEV SHORTCUT — the direct store write, kept and named',
      contractAddress: report.contractAddress,
      contractClassId: report.contractClassId,
      outcome: report.outcome,
      revertCode: report.revertCode,
      registeredClasses: report.registeredClasses,
      registeredInstances: report.registeredInstances,
      executedSteps: executed === null ? 0 : executed.steps.length,
      contexts: executed === null ? 0 : new Set(executed.steps.map(s => s.contextId)).size,
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


// =============================================================================================
// M35 — PRIVATE EXECUTION. Two arms, and they answer two different questions.
// =============================================================================================
//
// `armPrivateExecution` runs REAL ACIR: upstream's `WASMSimulator` over the ACVM, upstream's oracle
// wire, our handler. One contract executes to completion on the oracles this milestone serves, and a
// second — Token's private `transfer` — is REFUSED BY NAME at the first oracle it needs that this
// milestone does not. Both outcomes are the deliverable; the second is the one the campaign's oldest
// rule is about, and it is measured on a real 76,875-byte circuit rather than asserted.
//
// `armOracleSurface` exercises the served set DIRECTLY, because "implemented" has to mean "observed
// to answer" rather than "a method exists". A contract that reaches four of thirty-three oracles
// cannot say anything about the other twenty-nine, and a handler whose unexercised methods returned
// plausible defaults would pass every assertion about the four.

let privateAssetsFetched = false;

async function requirePrivateAssets(): Promise<void> {
  if (privateAssetsFetched) return;
  say('fetching the ACVM and the ABI decoder (4.4 MB, and only now)');
  await initPrivateExecution({ acvmWasmUrl: ACVM_WASM_URL, noircAbiWasmUrl: NOIRC_ABI_WASM_URL });
  privateAssetsFetched = true;
}

async function fetchJson(url: string): Promise<unknown> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${response.status}`);
  return response.json();
}

/** ARM: two real private circuits — one that completes, one that refuses by name. */
async function armPrivateExecution(): Promise<Record<string, unknown>> {
  // THE RUNTIME FIRST, AND IT IS NOT INCIDENTAL. Under this build's DD-11 redirect table every
  // poseidon2 and grumpkin operation is `avm.wasm`'s, installed by `openAvmRuntime`; there is no
  // fallback to bb.js by design. A private frame's function SELECTOR is a poseidon hash of the ABI
  // signature, so a page that has not opened the module cannot even name the function it is about to
  // execute — measured, as `Poseidon2NotInstalled` out of Chromium's own error list on this arm's
  // first run. Opening it here also means the arm's network log carries `avm.wasm`, which is what
  // makes the ACVM's ABSENCE from the control arm's log a measurement rather than an empty set.
  await open();
  await requirePrivateAssets();
  const contract = toAddressValue(0x777n, 'demo contract');
  const sender = toAddressValue(0x333n, 'demo sender');
  const common = {
    contractAddress: contract,
    msgSender: sender,
    chainId: PRIVATE_CHAIN_ID,
    version: PRIVATE_CHAIN_VERSION,
    entropySeed: PRIVATE_ENTROPY_SEED,
    writeLine: (line: string) => say(line),
  };

  const oracleCheckArtifact = await fetchJson(ORACLE_CHECK_ARTIFACT_URL);
  const executes = await executePrivateFunction({
    ...common,
    artifact: oracleCheckArtifact,
    functionName: 'private_function',
    args: [],
  });
  say(`private_function: ${executes.outcome}, ${executes.oracleCalls.length} oracle call(s)`);

  const tokenArtifact = await loadArtifact();

  // THE LADDER, MEASURED ON EVERY RUN RATHER THAN ONCE IN A SPIKE.
  //
  // `PRIVATE-EXECUTION.md` section 3, the refusal reason on `aztec_utl_getContractInstance` and the
  // milestone's own goal section all say the same strong thing: `Token.transfer`,
  // `Token.mint_to_private` and `PrivateVoting.cast_vote` ALL stop at that one oracle, so tier 2's
  // boundary is a property of the ORACLE and not of one contract. Until this loop existed the arm
  // executed `transfer` and nothing else, and the other two rungs were a measurement taken once
  // during the milestone's spike and then written into three documents — *"a figure nobody re-derives
  // rots"*, on the sentence that decides what M36 has to build first. Three programs are run here and
  // the check compares the stops as a SET.
  //
  // THE ARGUMENT WIDTH IS TAKEN FROM THE THING UNDER TEST. `executePrivateFunction` refuses a wrong
  // field count naming the width the ABI declares, and this reads it back out of that refusal — which
  // is the campaign's own rule for a number a check needs that also exists in the subject. Nothing
  // here is a width typed into a demo.
  const votingArtifact = await fetchJson(VOTING_ARTIFACT_URL);

  // TIER 2, RUNG 1: EACH PROGRAM NOW RUNS AT ITS OWN CONTRACT'S OWN ADDRESS.
  //
  // Until `aztec_utl_getContractInstance` was served, every rung could share one made-up address
  // (`0x777`) because every rung stopped before anything looked at it. It cannot now, and the
  // reason is the circuit rather than a convention: `aztec-nr`'s `get_contract_instance` does
  // `assert_eq(instance.to_address(), address)`, so the address a frame runs at must be the address
  // the instance handed back DERIVES to. Running PrivateVoting's bytecode at Token's address was a
  // fiction the old arm got away with only because it never got that far.
  //
  // So each contract gets a REAL instance — upstream's own `makeContractInstanceFromClassId`, over
  // the class id derived from that artifact's own `public_dispatch` — and the frame runs at
  // `instance.address`, which that function derived rather than anybody typed. Nothing here is a
  // fabricated preimage: the address is a function OF the preimage, computed by upstream's code.
  const deployerForPrivate = await AztecAddress.fromNumber(4242);
  const instanceFor = async (doc: unknown, salt: number) => {
    const parsedDoc = doc as { name: string; functions: { name: string; bytecode: string }[] };
    const classId = await classIdOf(parsedDoc);
    // THE INITIALIZATION HASH IS UPSTREAM'S OWN ENCODING OF "NO INITIALIZER", DELIBERATELY, AND
    // THE TWO REJECTED ALTERNATIVES ARE WORTH RECORDING BECAUSE BOTH FAILED IN THE PAGE.
    //
    // What this rung measures is that the address a frame runs at is DERIVED from the preimage the
    // wallet hands back — the relation `aztec-nr`'s `get_contract_instance` asserts. That relation
    // holds for ANY consistent initialization hash, so the honest choice is the one that invents
    // nothing.
    //
    //   * Reading the constructor ABI off the RAW artifact json gives a function record with no
    //     `.parameters`, and the failure lands four frames away inside
    //     `FunctionSelector.fromNameAndParameters` as `Cannot read properties of undefined
    //     (reading 'map')` — measured, on PrivateVoting.
    //   * Reading it off the LOADED artifact works, and then Token's four constructor arguments are
    //     handed to PrivateVoting's one-argument constructor: `Function 'constructor' expects 1
    //     argument(s) but received 4`. Also measured.
    //
    // Both were attempts to make the hash "real", and a real hash of arguments nobody passed is not
    // more true than zero — it is a fiction with more steps.
    const initializationHash = await computeInitializationHash(undefined, []);
    return makeContractInstanceFromClassId(classId, salt, {
      deployer: deployerForPrivate,
      initializationHash,
      immutablesHash: new Fr(28),
      publicKeys: PublicKeys.default(),
    });
  };
  const tokenInstance = await instanceFor(tokenArtifact, 27);
  const votingInstance = await instanceFor(votingArtifact, 29);
  const heldInstances = [tokenInstance, votingInstance].map(i => ({
    address: i.address,
    salt: i.salt,
    deployer: i.deployer,
    originalContractClassId: i.originalContractClassId,
    initializationHash: i.initializationHash,
    immutablesHash: i.immutablesHash,
    publicKeys: i.publicKeys,
  }));
  say(
    `[wallet] holding ${heldInstances.length} contract instance(s): ` +
      heldInstances.map(i => i.address.toString()).join(', '),
  );

  // TIER 2, RUNG 2: THE ACCOUNT KEY DIRECTORY, AND IT IS THE WALLET'S OWN DERIVATION PUBLISHED
  // RATHER THAN A NEW SOURCE OF KEYS. `deriveDevAccounts` (RI-96) already produces exactly the
  // triple this oracle returns — public keys, partial address, and the address that
  // `computeAddress` derives FROM them — from a seed that is an argument and is never generated.
  // Nothing here is invented; the directory is a view of what `dev_keys.ts` already computes.
  const keyAccounts = await deriveDevAccounts(DEFAULT_DEV_WALLET_SEED, 3);
  const heldAccountKeys = keyAccounts.map(a => ({
    address: a.address,
    publicKeys: a.publicKeys,
    partialAddress: a.partialAddress,
  }));
  say(
    `[wallet] holding keys for ${heldAccountKeys.length} account(s): ` +
      heldAccountKeys.map(a => a.address.toString()).join(', '),
  );

  // THE MILESTONE'S HEADLINE REFUSAL, RE-TAKEN ONE RUNG HIGHER. This is the same 76,875-byte
  // `Token.transfer` M35 shipped, and it is still refused by name on a real circuit — but the
  // oracle it now stops at is the first one it needs that is genuinely UNIMPLEMENTED, rather than
  // tier 2's first rung. Serving `getContractInstance` did not weaken the rule; it moved the
  // boundary and left the rule measuring the same thing at the new one.
  const refuses = await executePrivateFunction({
    ...common,
    contractAddress: tokenInstance.address,
    contractInstances: heldInstances,
    accountKeys: heldAccountKeys,
    artifact: tokenArtifact,
    functionName: 'transfer',
    // `to` and `amount`, two fields, read as the ABI declares them. The values do not matter: the
    // frame stops before the circuit reads either.
    args: [0x444n, 5n],
  });
  say(`Token.transfer: ${refuses.outcome} at ${refuses.stoppedAtOracle ?? '(nothing)'}`);

  const ladder: Record<string, unknown>[] = [];
  for (const [doc, fnName, inst] of [
    [tokenArtifact, 'transfer', tokenInstance],
    [tokenArtifact, 'mint_to_private', tokenInstance],
    [votingArtifact, 'cast_vote', votingInstance],
  ] as const) {
    const at = {
      ...common,
      contractAddress: inst.address,
      contractInstances: heldInstances,
      accountKeys: heldAccountKeys,
      artifact: doc,
      functionName: fnName,
    };
    let rung;
    try {
      rung = await executePrivateFunction({ ...at, args: [] });
    } catch (e) {
      const declared = /declares (\d+) argument field\(s\)/.exec(String((e as Error).message));
      if (!declared) throw e;
      rung = await executePrivateFunction({ ...at, args: new Array(Number(declared[1])).fill(0n) });
    }
    ladder.push({
      contractName: rung.contractName,
      functionName: rung.functionName,
      functionType: rung.functionType,
      bytecodeBytes: rung.bytecodeBytes,
      argFields: rung.argFields,
      outcome: rung.outcome,
      stoppedAtOracle: rung.stoppedAtOracle,
      oraclesServed: rung.oraclesServed,
      oraclesRefused: rung.oraclesRefused,
      ranAt: inst.address.toString(),
      // THE SET, NOT JUST THE COUNT, AND IT IS WHAT MAKES THE CIRCUIT'S OWN ASSERTION READABLE
      // FROM OUTSIDE. `aztec_utl_getContractInstance` appearing here as SERVED means the frame
      // asked for the instance, got the preimage, and CARRIED ON — and carrying on is only
      // possible if `assert_eq(instance.to_address(), address)` held inside the circuit. A count
      // of four would be satisfied by four other oracles.
      servedOracles: rung.oracleCalls.filter(c => c.outcome === 'served').map(c => c.oracle),
      // A RUNG CAN NOW STOP WITHOUT AN ORACLE REFUSING, and the error is the only place that says
      // why. Tier 2 rung 2 returns `Option::none()` for an account it does not hold, so the frame
      // is halted by UPSTREAM'S OWN named assertion inside the circuit rather than by a throw of
      // ours — `outcome: failed`, `stoppedAtOracle: null`, and the reason readable only here.
      oracleCalls: rung.oracleCalls,
      error: rung.error ?? null,
      errorChain: rung.errorChain ?? null,
    });
    say(`${rung.contractName}.${fnName}: ${rung.outcome} at ${rung.stoppedAtOracle ?? '(nothing)'}`);
  }

  // THE CONTROL THE SERVED ORACLE NEEDS, AND IT IS THE HALF THAT KEEPS THE RULE. "Served" must not
  // mean "answers anything". The same program, the same directory, at an address the wallet does
  // NOT hold: the oracle is reached and REFUSES, by name, as `ContractInstanceNotHeld` — a
  // different refusal from `OracleUnimplemented` and recorded as one.
  const unheldAddress = await AztecAddress.fromNumber(0x5150);
  const unheld = await executePrivateFunction({
    ...common,
    contractAddress: unheldAddress,
    contractInstances: heldInstances,
    accountKeys: heldAccountKeys,
    artifact: tokenArtifact,
    functionName: 'transfer',
    args: [0x444n, 5n],
  });
  say(`Token.transfer at an unheld address: ${unheld.outcome} at ${unheld.stoppedAtOracle ?? '(nothing)'}`);

  // AND THE CONTROL FOR THE GUARD. A directory entry whose preimage does not derive to the address
  // it is filed under is refused BEFORE the frame starts, naming both derivations — rather than
  // reaching the ACVM and failing as an unsatisfied constraint the reader has to work backwards
  // from. Recorded as the message, so the check reads what a caller would see.
  let inconsistentDirectoryError = '';
  try {
    await executePrivateFunction({
      ...common,
      contractAddress: tokenInstance.address,
      contractInstances: [{ ...heldInstances[0]!, salt: new Fr(0x1234) }],
      artifact: tokenArtifact,
      functionName: 'transfer',
      args: [0x444n, 5n],
    });
  } catch (e) {
    inconsistentDirectoryError = String((e as Error).message);
  }
  say(`inconsistent directory: ${inconsistentDirectoryError.slice(0, 80)}`);

  // RUNG 2'S GUARD CONTROL. Same shape as the one above and it matters more, because
  // `try_get_public_keys` does not constrain what this oracle returns: on that path an incoherent
  // triple is caught by nothing downstream at all.
  let inconsistentKeysError = '';
  try {
    await executePrivateFunction({
      ...common,
      contractAddress: tokenInstance.address,
      contractInstances: heldInstances,
      accountKeys: [{ ...heldAccountKeys[0]!, partialAddress: new Fr(0x99) }],
      artifact: tokenArtifact,
      functionName: 'transfer',
      args: [0x444n, 5n],
    });
  } catch (e) {
    inconsistentKeysError = String((e as Error).message);
  }
  say(`inconsistent keys: ${inconsistentKeysError.slice(0, 80)}`);

  // THE SAME SEED TWICE, IN TWO SEPARATE HANDLERS. `getRandomField` is the one served oracle that
  // WOULD read ambient entropy in any other wallet, and a recording whose fields differ per run is a
  // recording that does not replay. Two handlers, same seed, four draws each, compared.
  const draw = async (seed: bigint) => {
    const h = createPrivateOracleHandler({ contractAddress: contract, entropySeed: toFieldValue(seed, 'seed') });
    const out: string[] = [];
    for (let i = 0; i < 4; i++) {
      out.push(String(await (h.handler as Record<string, () => Promise<unknown>>).getRandomField()));
    }
    return out;
  };
  const entropyA = await draw(PRIVATE_ENTROPY_SEED);
  const entropyB = await draw(PRIVATE_ENTROPY_SEED);
  const entropyOther = await draw(PRIVATE_ENTROPY_SEED + 1n);

  const report = {
    executes: jsonSafe(executes),
    refuses: jsonSafe(refuses),
    ladder: jsonSafe(ladder),
    // THE ADDRESS THIS ARM ASKED FOR, so the check can compare the circuit's ECHO against the
    // REQUEST instead of against a literal typed into the check. The milestone declared that literal
    // as the lesser form of "a constant you have just typed into a check looks like a measurement";
    // two producers out of one run is what the neighbouring `returnsHash` assertion already does, and
    // this is the same shape for the address.
    requestedContractAddress: contract.toString(),
    // TIER 2 RUNG 1'S OWN EVIDENCE. The directory the wallet held, the control at an address it did
    // not, and the guard's message — each reported rather than summarised, so the check reads what
    // the run produced instead of a boolean somebody computed in the page.
    heldInstances: heldInstances.map(i => ({
      address: i.address.toString(),
      salt: i.salt.toString(),
      deployer: i.deployer.toString(),
      originalContractClassId: i.originalContractClassId.toString(),
      initializationHash: i.initializationHash.toString(),
      immutablesHash: i.immutablesHash.toString(),
    })),
    unheld: jsonSafe(unheld),
    unheldAddress: unheldAddress.toString(),
    inconsistentDirectoryError,
    // Tier 2 rung 2's evidence: the accounts held, and the guard's message.
    heldAccountKeys: heldAccountKeys.map(a => ({
      address: a.address.toString(),
      partialAddress: a.partialAddress.toString(),
      npkMHash: a.publicKeys.npkMHash.toString(),
    })),
    inconsistentKeysError,
    entropy: { a: entropyA, b: entropyB, other: entropyOther },
    assets: privateExecutionAssets(),
  };
  lastRun = report;
  return report;
}

/**
 * ARM: every served oracle, exercised through the handler, and every refused one required to refuse.
 *
 * The exercises are behavioural rather than smoke: a push is followed by a length, a set by a get, a
 * delete by a miss, a created nullifier by the question that has to answer `true` and by the same
 * question from another contract that has to answer `false`. `exercised` is the SET of oracle names
 * this arm actually reached, so a check can assert it equals the declared implemented set instead of
 * counting its own intentions.
 */
async function armOracleSurface(): Promise<Record<string, unknown>> {
  // `siloNullifier` is a poseidon2 hash and `isNullifierPending` is one of the oracles exercised
  // below, so this arm needs the module for the same reason the one above it does.
  await open();
  const contract = toAddressValue(0x777n, 'demo contract');
  const other = toAddressValue(0x778n, 'another contract');
  const scope = toAddressValue(0x999n, 'scope');
  // TIER 2 RUNG 1 IS EXERCISED HERE TOO, and it has to be: `verify_oracle_coverage_is_measured`
  // asserts the set of oracles this arm REACHED equals the declared implemented set in BOTH
  // directions, so an oracle that moved into the served list and was not exercised here is caught
  // as an unexercised method rather than quietly trusted. The instance is a real one — its address
  // is what upstream's own derivation produced from the preimage below, not a number typed here.
  const surfaceInstance = await makeContractInstanceFromClassId(new Fr(0x515n), 31, {
    deployer: await AztecAddress.fromNumber(4242),
    initializationHash: await computeInitializationHash(undefined, []),
    immutablesHash: new Fr(28),
    publicKeys: PublicKeys.default(),
  });
  const surfaceAccount = (await deriveDevAccounts(DEFAULT_DEV_WALLET_SEED, 1))[0]!;
  const handle = createPrivateOracleHandler({
    contractAddress: contract,
    entropySeed: toFieldValue(PRIVATE_ENTROPY_SEED, 'seed'),
    writeLine: (line: string) => say(line),
    accountKeys: [
      {
        address: surfaceAccount.address,
        publicKeys: surfaceAccount.publicKeys,
        partialAddress: surfaceAccount.partialAddress,
      },
    ],
    contractInstances: [
      {
        address: surfaceInstance.address,
        salt: surfaceInstance.salt,
        deployer: surfaceInstance.deployer,
        originalContractClassId: surfaceInstance.originalContractClassId,
        initializationHash: surfaceInstance.initializationHash,
        immutablesHash: surfaceInstance.immutablesHash,
        publicKeys: surfaceInstance.publicKeys,
      },
    ],
  });
  const h = handle.handler as Record<string, (...args: unknown[]) => unknown>;
  const F = (n: bigint) => toFieldValue(n, 'field');
  const fieldDecimal = (v: unknown) => String((v as { toBigInt?: () => bigint })?.toBigInt?.() ?? v);
  const observations: Record<string, string> = {};

  // misc
  await h.assertCompatibleOracleVersion(ORACLE_ENVIRONMENT_VERSION.major, 0);
  observations.assertCompatibleOracleVersion = 'accepted a matching major';
  h.log(1, 'hello from the surface arm', 1, [F(7n)]);
  observations.log = 'wrote one line';
  const r0 = String(await h.getRandomField());
  const r1 = String(await h.getRandomField());
  observations.getRandomField = `${r0 === r1 ? 'REPEATED' : 'advanced'}`;

  // tier 2 rung 1 — BOTH DIRECTIONS, because an oracle that answers everything and an oracle that
  // answers what it holds look identical from a single hit. The held address must come back with
  // the preimage that derives to it; an address the directory does not carry must THROW.
  const gotInstance = (await h.getContractInstance(surfaceInstance.address)) as {
    originalContractClassId: { toString(): string };
  };
  observations.getContractInstance =
    gotInstance.originalContractClassId.toString() === surfaceInstance.originalContractClassId.toString()
      ? 'answered with the class id it was filed under'
      : 'ANSWERED WITH THE WRONG CLASS ID';
  try {
    await h.getContractInstance(await AztecAddress.fromNumber(0x6161));
    observations.getContractInstanceMiss = 'ANSWERED FOR AN ADDRESS IT DOES NOT HOLD';
  } catch (e) {
    observations.getContractInstanceMiss = `refused as ${(e as Error).name}`;
  }

  // tier 2 rung 2 — BOTH DIRECTIONS, and the miss is an ANSWER here rather than a throw, because
  // the oracle's declared return is an Option and the protocol defines the "not registered"
  // encoding. A handler that threw would break `try_get_public_keys`, whose whole purpose is to
  // ask and accept `None`.
  const gotKeys = (await h.getPublicKeysAndPartialAddress(surfaceAccount.address)) as {
    value?: { partialAddress: { toString(): string } };
  };
  observations.getPublicKeysAndPartialAddress =
    gotKeys.value?.partialAddress.toString() === surfaceAccount.partialAddress.toString()
      ? 'answered with the partial address that derives its own key'
      : 'ANSWERED WITH THE WRONG PARTIAL ADDRESS';
  const missKeys = (await h.getPublicKeysAndPartialAddress(await AztecAddress.fromNumber(0x6262))) as {
    value?: unknown;
  };
  observations.getPublicKeysAndPartialAddressMiss =
    missKeys.value === undefined ? 'answered none for an unregistered account' : 'ANSWERED FOR AN UNKNOWN ACCOUNT';

  // capsules
  h.setCapsule(contract, F(1n), [F(11n), F(12n)], scope);
  const cap = h.getCapsule(contract, F(1n), 2, scope) as { value?: unknown[] };
  observations.setCapsule = 'stored two fields';
  observations.getCapsule = cap.value ? `read ${String((cap.value as unknown[]).length)} field(s)` : 'MISS';
  h.setCapsule(contract, F(2n), [F(21n)], scope);
  h.copyCapsule(contract, F(2n), F(3n), 1, scope);
  observations.copyCapsule = (h.getCapsule(contract, F(3n), 1, scope) as { value?: unknown }).value
    ? 'copied one slot'
    : 'MISS';
  // THE OVERLAPPING COPY, WHICH IS THE ONE A FORWARD-ONLY LOOP GETS WRONG. Slots 10..12 hold
  // 1, 2, 3; copying three entries from 10 to 11 must leave 11..13 holding 1, 2, 3, and a forward
  // walk leaves 1, 1, 1 because it overwrites 11 before reading it. Upstream reverses the order when
  // the destination is ahead of the source; the observation is the DESTINATION READ BACK, so a copy
  // that ran in the wrong direction reports its own wrong answer rather than 'copied'.
  for (const [slot, value] of [[10n, 1n], [11n, 2n], [12n, 3n]] as const) {
    h.setCapsule(contract, F(slot), [F(value)], scope);
  }
  h.copyCapsule(contract, F(10n), F(11n), 3, scope);
  observations.copyCapsuleOverlapping = [11n, 12n, 13n]
    .map(slot => {
      const got = (h.getCapsule(contract, F(slot), 1, scope) as { value?: unknown[] }).value;
      return got ? fieldDecimal(got[0]) : 'MISS';
    })
    .join(',');
  h.deleteCapsule(contract, F(1n), scope);
  observations.deleteCapsule = (h.getCapsule(contract, F(1n), 2, scope) as { value?: unknown }).value
    ? 'STILL THERE'
    : 'gone';

  // ephemeral and transient arrays, the same seven operations over two different keyings
  for (const family of ['Ephemeral', 'Transient'] as const) {
    const slot = F(family === 'Ephemeral' ? 100n : 200n);
    h[`push${family}`](slot, [F(1n)]);
    h[`push${family}`](slot, [F(2n)]);
    observations[`push${family}`] = `len ${String(h[`get${family}Len`](slot))}`;
    observations[`get${family}Len`] = `len ${String(h[`get${family}Len`](slot))}`;
    h[`set${family}`](slot, 0, [F(9n)]);
    observations[`set${family}`] = 'wrote index 0';
    // Rendered as a DECIMAL rather than as an `Fr`'s 66-character hex, so the assertion that reads
    // it is legible. The value is the field's own `toBigInt()`, not a re-encoding.
    observations[`get${family}`] = `index 0 is ${fieldDecimal((h[`get${family}`](slot, 0) as unknown[])[0])}`;
    observations[`pop${family}`] = `popped ${fieldDecimal((h[`pop${family}`](slot) as unknown[])[0])}`;
    h[`remove${family}`](slot, 0);
    observations[`remove${family}`] = `len ${String(h[`get${family}Len`](slot))}`;
    h[`push${family}`](slot, [F(5n)]);
    h[`clear${family}`](slot);
    observations[`clear${family}`] = `len ${String(h[`get${family}Len`](slot))}`;
  }

  // sinks
  h.setContractSyncCacheInvalid(contract, { data: [scope] });
  observations.setContractSyncCacheInvalid = 'accepted one scope';
  h.emitOffchainEffect([F(1n), F(2n)]);
  observations.emitOffchainEffect = 'accepted two fields';

  // the execution cache
  h.setHashPreimage([F(41n), F(42n)], F(4142n));
  observations.setHashPreimage = 'stored a two-field preimage';
  observations.getHashPreimage = `read ${String((h.getHashPreimage(F(4142n)) as unknown[]).length)} field(s)`;
  h.assertValidPublicCalldata(F(4142n));
  observations.assertValidPublicCalldata = 'accepted a hash that is in the cache';
  // THE CAP, EXERCISED. One preimage larger than the whole-transaction limit must be refused, and
  // the limit is upstream's constant rather than a number typed here.
  let calldataCapRefused = 'NOT REFUSED';
  try {
    const huge = new Array(MAX_FR_CALLDATA_TO_ALL_ENQUEUED_CALLS + 1).fill(F(1n));
    h.setHashPreimage(huge, F(777777n));
    h.assertValidPublicCalldata(F(777777n));
  } catch (e) {
    calldataCapRefused = String((e as Error).message).slice(0, 200);
  }
  let calldataMissRefused = 'NOT REFUSED';
  try {
    h.assertValidPublicCalldata(F(999999n));
  } catch (e) {
    calldataMissRefused = String((e as Error).message).slice(0, 200);
  }

  // the notify* family and the two questions answered from it
  h.notifyCreatedNote(contract, F(5n), F(6n), F(7n), [F(8n)], F(9n), 1);
  observations.notifyCreatedNote = 'recorded one note';
  await h.notifyNullifiedNote(F(10n), F(9n), 2);
  observations.notifyNullifiedNote = 'recorded one nullified note';
  // THE OTHER DIRECTION: a note nobody created cannot be consumed. Upstream refuses it and so does
  // this, and without the negative case "recorded one nullified note" is satisfied by a handler that
  // records anything it is handed.
  let unknownNoteRefused = 'NOT REFUSED';
  try {
    await h.notifyNullifiedNote(F(12n), F(0xdeadn), 3);
  } catch (e) {
    unknownNoteRefused = String((e as Error).message).slice(0, 200);
  }
  await h.notifyCreatedNullifier(F(11n));
  observations.notifyCreatedNullifier = 'recorded one nullifier';
  // AND THE DUPLICATE. A `Set.add` of an existing member is a no-op, so a permissive handler is not
  // visibly wrong afterwards — the refusal is the only thing that distinguishes them.
  let duplicateNullifierRefused = 'NOT REFUSED';
  try {
    await h.notifyCreatedNullifier(F(11n));
  } catch (e) {
    duplicateNullifierRefused = String((e as Error).message).slice(0, 200);
  }
  observations.isNullifierPending =
    `own=${String(await h.isNullifierPending(F(11n), contract))} ` +
    `other=${String(await h.isNullifierPending(F(11n), other))}`;
  h.notifyCreatedContractClassLog(contract, [F(1n)], 1, 3);
  observations.notifyCreatedContractClassLog = 'recorded one class log';
  const beforePhase = String(h.isExecutionInRevertiblePhase(5));
  h.notifyRevertiblePhaseStart(5);
  observations.notifyRevertiblePhaseStart = 'entered at counter 5';
  observations.isExecutionInRevertiblePhase =
    `before=${beforePhase} after5=${String(h.isExecutionInRevertiblePhase(5))} ` +
    `after4=${String(h.isExecutionInRevertiblePhase(4))}`;

  // AN ORACLE NAME THE REGISTRY DOES NOT DECLARE — the OTHER half of "a bytecode/oracle mismatch is
  // loud", and the half the version assertion cannot cover. `buildACIRCallback` wraps its table in a
  // Proxy whose trap fires for exactly this, and the diagnostic it picks depends on whether the
  // handler carries `nonOracleFunctionGetContractOracleVersion`. Driven through the REAL callback
  // rather than the handler, because the trap is the callback's and not the handler's.
  const callback = buildACIRCallback(handle.handler as never) as unknown as Record<string, () => Promise<unknown>>;
  let unknownOracle = 'NOT REFUSED';
  try {
    await callback['aztec_utl_thisOracleDoesNotExist']();
  } catch (e) {
    unknownOracle = String((e as Error).message).slice(0, 400);
  }
  // ...and a DECLARED one reaches the HANDLER through the same callback, so the trap is shown to
  // discriminate rather than to refuse everything.
  //
  // THE ORACLE IS CHOSEN FOR ITS ARITY AND THAT IS M34'S FINDING IN A SECOND PLACE. A first version
  // called `aztec_utl_getNotes` with no inputs and got a `TypeError` from
  // `entry.deserializeParams` — upstream's codec rejects the SLOT COUNT before the handler is
  // reached, so the control measured somebody else's refusal rather than this one. That is exactly
  // M34's refusals arm, where all six "refusals" turned out to be `parseWithOptionals`.
  // `aztec_prv_getSenderForTags` is `makeEntry({ returnType: … })` with NO params, so no-argument is
  // its real wire and the call reaches the handler.
  let knownOracleThroughCallback = 'NOT REACHED';
  try {
    await callback['aztec_prv_getSenderForTags']();
  } catch (e) {
    knownOracleThroughCallback = String((e as Error).name);
  }

  // EVERY REFUSED ORACLE, CALLED DIRECTLY, AND REQUIRED TO NAME ITSELF.
  const refusals: Record<string, { name: string; namesItself: boolean; message: string }> = {};
  for (const oracle of ORACLE_REFUSING) {
    const method = oracleMethodName(oracle);
    try {
      await (h[method] as () => Promise<unknown>)();
      refusals[oracle] = { name: 'RESOLVED', namesItself: false, message: 'the oracle returned a value' };
    } catch (e) {
      const err = e as { name?: string; message?: string; oracle?: string; reason?: string };
      refusals[oracle] = {
        name: String(err.name),
        namesItself: err.oracle === oracle && String(err.message).includes(oracle),
        message: String(err.message).slice(0, 200),
      };
    }
  }

  // The construction-time guard, exercised in both directions over the BUILT bundle.
  const guard = { correct: 'NOT RUN', missing: 'NOT RUN', extra: 'NOT RUN' };
  const allMethods = ORACLE_NAMES.map(oracleMethodName);
  try {
    assertOracleSurfaceMatchesDeclaration(allMethods);
    guard.correct = 'accepted';
  } catch (e) {
    guard.correct = `REFUSED: ${String((e as Error).message)}`;
  }
  try {
    assertOracleSurfaceMatchesDeclaration(allMethods.slice(1));
    guard.missing = 'ACCEPTED A LIST WITH ONE NAME DROPPED';
  } catch (e) {
    guard.missing = String((e as Error).message).slice(0, 160);
  }
  try {
    assertOracleSurfaceMatchesDeclaration([...allMethods, 'aFabricatedOracleName']);
    guard.extra = 'ACCEPTED A LIST WITH A FABRICATED NAME';
  } catch (e) {
    guard.extra = String((e as Error).message).slice(0, 160);
  }

  const ledger = handle.calls();
  const exercised = [...new Set(ledger.filter(c => c.outcome === 'served').map(c => c.oracle))].sort();
  const report = {
    registry: {
      total: ORACLE_NAMES.length,
      implemented: [...ORACLE_IMPLEMENTED],
      refusing: [...ORACLE_REFUSING],
      reasons: { ...ORACLE_REFUSAL_REASONS },
      environmentVersion: { ...ORACLE_ENVIRONMENT_VERSION },
      ephemeralReturnOracles: [...EPHEMERAL_RETURN_ORACLES],
      ephemeralReturnLabels: { ...ORACLE_EPHEMERAL_RETURN_LABELS },
      // THE THREE SCOPE MARKERS, EXCLUDED BY NAME AND NOT BY PREFIX. A first draft dropped every
      // key starting with `is`, which also dropped `isNullifierPending` and
      // `isExecutionInRevertiblePhase` — two real oracles — and reported 66 for a handler carrying
      // 68 methods plus 3 markers. The count is the thing a check compares against the registry, so
      // a needle that is too wide reads as a handler two methods short.
      handlerMethods: Object.keys(h).filter(
        k => !['isMisc', 'isUtility', 'isPrivate', 'nonOracleFunctionGetContractOracleVersion'].includes(k),
      ).length,
      handlerMarkers: ['isMisc', 'isUtility', 'isPrivate'].filter(k => k in h).length,
      // The NON-ORACLE methods, counted separately rather than folded into either number. Upstream
      // prefixes this one `nonOracleFunction` precisely because `buildACIRCallback` never dispatches
      // to it; counting it as a 69th oracle would say the handler serves one the registry has never
      // heard of, and excluding it silently would leave the unknown-oracle trap's own input unstated.
      handlerNonOracle: ['nonOracleFunctionGetContractOracleVersion'].filter(k => k in h).length,
    },
    exercised,
    observations,
    calldataMissRefused,
    unknownNoteRefused,
    duplicateNullifierRefused,
    calldataCapRefused,
    maxCalldata: MAX_FR_CALLDATA_TO_ALL_ENQUEUED_CALLS,
    unknownOracle,
    knownOracleThroughCallback,
    refusals,
    guard,
    ledger: ledger.map(c => ({ seq: c.seq, oracle: c.oracle, outcome: c.outcome })),
  };
  lastRun = report;
  return jsonSafe(report);
}

const api = {
  armWalletTransfer,
  armRefusals,
  armDeterministicKeys,
  armRecord,
  armDirectShortcut,
  armPrivateExecution,
  armOracleSurface,
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
  'btn-private-execution': () => armPrivateExecution(),
  'btn-oracle-surface': () => armOracleSurface(),
})) {
  document.getElementById(id)?.addEventListener('click', () => {
    (fn as () => Promise<unknown>)().catch((e: unknown) => say(`ERROR ${String(e)}`));
  });
}
