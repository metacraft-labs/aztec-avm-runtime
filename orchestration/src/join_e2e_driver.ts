// join_e2e_driver.ts — M26: the half of the join arms that touches `@aztec/*`.
//
// M22's `block_e2e_driver.ts` shape, and for M22's reason: `tools/run_join_arms.mjs` lives outside
// this package, so a bare `@aztec/stdlib` import THERE does not resolve — node's ESM resolution
// walks up from the importing FILE, not from the cwd. Everything that needs this package's
// `node_modules` therefore lives here and the tool imports it relatively, exactly as
// `run_block_arms.mjs` imports `block_e2e_driver.ts`.
//
// ---------------------------------------------------------------------------
// WHAT THIS FILE IS FOR: **a transaction that calls a registered contract**, which is the
// capability M18, M22, M23 and M25 each deferred and RI-72 finally priced. It uses upstream's own
// builder — vendored under `src/vendor/` at the `ts` anchor — rather than a transaction this
// repository assembled, because the whole point of the vendoring is that the transaction is the one
// upstream builds.
//
// THE MERKLE TRIPWIRE IS THE DELIVERABLE'S OWN EVIDENCE, NOT A CONVENIENCE. RI-72's load-bearing
// measurement is that the reduced closure stores its `MerkleTreeWriteOperations` and NEVER CALLS
// IT — `grep -c 'merkleTree\.'` is 0 against 7 mentions at the anchor — which is why the reduced
// set needs no merkle implementation and why the vendoring severs `@aztec/world-state` cleanly. A
// grep is a claim about text. Here the parameter is a `Proxy` that THROWS on every read, every
// `in` and every enumeration, so the same claim is executed: if a re-vendoring ever brought back a
// call, this driver would fail at the call rather than quietly need a world state.
// ---------------------------------------------------------------------------

import { Fr } from '@aztec/foundation/curves/bn254';
import { loadContractArtifact } from '@aztec/stdlib/abi';
import { AztecAddress } from '@aztec/stdlib/aztec-address';

import {
  JOIN_EVENT_METADATA,
  JOIN_REASON,
  TraceJoinRefused,
  formatJoinRecord,
  joinRecord,
  joinRecordings,
  parseJoinRecord,
  privateTraceHandleFor,
  type HalfRecording,
  type JoinArm,
} from './trace_join.ts';
import { locallyExecutedTx } from './submitted_tx.ts';
import {
  createContractClassAndInstance,
  getContractFunctionAbi,
  getFunctionSelector,
} from './vendor/avm_fixtures_utils.ts';
import { PublicTxSimulationTester } from './vendor/public_tx_simulation_tester.ts';
import { SimpleContractDataSource } from './vendor/simple_contract_data_source.ts';

/** The function the joined recording's public half calls. */
export const JOIN_FIXTURE_FUNCTION = 'transfer_in_public';
/** The SECOND enqueued call, so "in the order they were enqueued" is a claim about two things. */
export const JOIN_SECOND_FUNCTION = 'balance_of_public';
/** A third call, used only as the control that the builder is not producing one fixed answer. */
export const JOIN_CONTROL_FUNCTION = 'total_supply';

export interface JoinTransaction {
  readonly artifactName: string;
  readonly aztecVersion: string | null;
  readonly contractAddress: string;
  readonly contractClassId: string;
  readonly packedBytecodeBytes: number;
  readonly fnName: string;
  readonly fnSelector: string;
  readonly fnParameters: number;
  /** Upstream's own `<Artifact>.<fn>`, from `SimpleContractDataSource.getDebugFunctionName`. */
  readonly debugFunctionName: string | undefined;
  /** Both enqueued calls' debug names, in enqueue order. */
  readonly enqueuedNames: readonly (string | undefined)[];
  readonly enqueuedSelectors: readonly string[];
  readonly enqueuedCalldataFields: readonly number[];
  readonly enqueuedCalldataSelectors: readonly string[];
  readonly txHash: string;
  readonly controlTxHash: string;
  readonly enqueuedPublicCalls: number;
  readonly setupPublicCalls: number;
  readonly calldataFields: number;
  readonly calldataSelector: string;
  /** Every observation the vendored builder made of its `merkleTree`. Expected empty. */
  readonly merkleTouches: readonly string[];
  /**
   * THE CONTROL FOR THAT EMPTY LIST, and it answers the question the list cannot.
   *
   * Every trap throws, so any observation aborts this function and no report is produced at all —
   * which means `merkleTouches` is necessarily empty in every report a check can read, and an
   * assertion that it is empty is satisfied by a tripwire wired to nothing. What has to be shown
   * is that the object the TESTER holds is the live throwing proxy: this field is produced by
   * reading `tester.merkleTree` back off the builder after the transaction is built and touching
   * THAT, so it is the same reference the vendored code was handed rather than a second one made
   * beside it. `NOT-THROWN` means the tripwire is not armed and the zero above means nothing.
   */
  readonly merkleTripwireControl: string;
  /** How many observations the control's deliberate touch recorded. Expected 1. */
  readonly merkleTouchesAfterControl: number;
  readonly registeredClasses: number;
  readonly registeredInstances: number;
  /** `public_dispatch`'s bytecode, base64, for the tool's own source-map decode. */
  readonly dispatchBytecodeBase64: string;
  /** `public_dispatch`'s `debug_symbols`, base64 raw-DEFLATE JSON. */
  readonly dispatchDebugSymbolsBase64: string;
  /** The artifact's `file_map`, as `{ id: { path, source } }`. */
  readonly fileMap: Record<string, { path: string; source: string }>;
}

/**
 * Build the transaction, from a contract artifact JSON this function is handed.
 *
 * The artifact arrives as already-parsed JSON rather than as a path, so the SEARCH for it — which
 * has to cross node_modules roots carrying two different `@aztec` nightly lines — stays in the tool
 * where its residue can be reported.
 */
export async function buildJoinTransaction(rawArtifact: unknown): Promise<JoinTransaction> {
  const artifact = loadContractArtifact(rawArtifact as never);
  const deployer = await AztecAddress.fromNumber(4242);
  const sender = await AztecAddress.fromNumber(1001);
  const { contractClass, contractInstance } = await createContractClassAndInstance(
    [deployer, 'Tok', 'TOK', 18],
    deployer,
    artifact,
    27,
  );
  const dataSource = new SimpleContractDataSource();
  await dataSource.addNewContract(artifact, contractClass, contractInstance);

  const merkleTouches: string[] = [];
  const merkleTripwire = new Proxy(
    {},
    {
      get(_t, p) {
        merkleTouches.push(`get:${String(p)}`);
        throw new Error(`the vendored transaction builder read merkleTree.${String(p)}`);
      },
      has(_t, p) {
        merkleTouches.push(`has:${String(p)}`);
        throw new Error(`the vendored transaction builder asked '${String(p)}' in merkleTree`);
      },
      ownKeys() {
        merkleTouches.push('ownKeys');
        throw new Error('the vendored transaction builder enumerated merkleTree');
      },
    },
  );

  const tester = new PublicTxSimulationTester(merkleTripwire as never, dataSource);
  // TWO enqueued calls, and the second one is not decoration: M26's deliverable is that the public
  // calls appear "in the order they were enqueued", and an assertion about the order of a
  // one-element list cannot fail. The two are DIFFERENT functions, so the order is checkable by
  // name rather than by position in a list of identical things.
  const tx = await tester.createTx(sender, [], [
    {
      address: contractInstance.address,
      fnName: JOIN_FIXTURE_FUNCTION,
      args: [sender, deployer, 5n, new Fr(0)],
    },
    { address: contractInstance.address, fnName: JOIN_SECOND_FUNCTION, args: [sender] },
  ]);
  // The control that the builder is not producing one fixed answer: the SAME tester, one call, a
  // different function, and therefore a different transaction hash.
  const control = await tester.createTx(sender, [], [
    { address: contractInstance.address, fnName: JOIN_CONTROL_FUNCTION, args: [] },
  ]);

  const selector = await getFunctionSelector(JOIN_FIXTURE_FUNCTION, artifact);
  const secondSelector = await getFunctionSelector(JOIN_SECOND_FUNCTION, artifact);
  const fnAbi = getContractFunctionAbi(JOIN_FIXTURE_FUNCTION, artifact);
  const forPublic = (tx as never as { data: { forPublic: never } }).data.forPublic as {
    revertibleAccumulatedData: { publicCallRequests: { isEmpty(): boolean }[] };
    nonRevertibleAccumulatedData: { publicCallRequests: { isEmpty(): boolean }[] };
  };
  const enqueued = forPublic.revertibleAccumulatedData.publicCallRequests.filter(r => !r.isEmpty());
  const setup = forPublic.nonRevertibleAccumulatedData.publicCallRequests.filter(r => !r.isEmpty());
  const calldataAll = (tx as never as { publicFunctionCalldata: { values: Fr[] }[] })
    .publicFunctionCalldata;
  const calldata = calldataAll[0]!;

  // THE TRIPWIRE'S CONTROL, TAKEN AFTER THE BUILD AND OFF THE TESTER ITSELF.
  //
  // `merkleTouches` cannot be non-empty in any report a reader ever sees — every trap throws, so an
  // observation aborts this function before the report exists. So "zero observations" is true of a
  // tripwire that was never wired to anything, and the assertion on it needs a partner that says
  // the wiring is real. `tester.merkleTree` is the field the vendored constructor assigned
  // (`vendor/public_tx_simulation_tester.ts:61`), so touching it touches the reference the builder
  // was handed, not a second proxy made here.
  const observedDuringBuild = [...merkleTouches];
  let tripwireControl = 'NOT-THROWN';
  try {
    void (tester as never as { merkleTree: Record<string, unknown> }).merkleTree['getTreeInfo'];
  } catch (e) {
    tripwireControl = `threw:${e instanceof Error ? e.message : String(e)}`;
  }
  const touchesAfterControl = merkleTouches.length;

  const dispatch = artifact.functions.find(f => f.name === 'public_dispatch');
  if (dispatch === undefined) {
    throw new Error(`${artifact.name} has no public_dispatch function`);
  }
  const raw = rawArtifact as {
    aztec_version?: string;
    file_map?: Record<string, { path: string; source: string }>;
    functions: { name: string; bytecode: string; debug_symbols: string }[];
  };
  const rawDispatch = raw.functions.find(f => f.name === 'public_dispatch');
  if (rawDispatch === undefined) {
    throw new Error('the raw artifact has no public_dispatch function');
  }

  return {
    artifactName: artifact.name,
    aztecVersion: raw.aztec_version ?? null,
    contractAddress: contractInstance.address.toString(),
    contractClassId: contractClass.id.toString(),
    packedBytecodeBytes: contractClass.packedBytecode.length,
    fnName: JOIN_FIXTURE_FUNCTION,
    fnSelector: selector.toString(),
    fnParameters: fnAbi?.parameters.length ?? -1,
    debugFunctionName: await dataSource.getDebugFunctionName(contractInstance.address, selector),
    // The two enqueued calls, in the order the builder put them in the transaction, named through
    // upstream's own mechanism. This list is what the trace's frame names are compared against.
    enqueuedNames: [
      await dataSource.getDebugFunctionName(contractInstance.address, selector),
      await dataSource.getDebugFunctionName(contractInstance.address, secondSelector),
    ],
    enqueuedSelectors: [selector.toString(), secondSelector.toString()],
    enqueuedCalldataFields: calldataAll.map(c => c.values.length),
    enqueuedCalldataSelectors: calldataAll.map(c => c.values[0]!.toString()),
    txHash: (await tx.getTxHash()).toString(),
    controlTxHash: (await control.getTxHash()).toString(),
    enqueuedPublicCalls: enqueued.length,
    setupPublicCalls: setup.length,
    calldataFields: calldata.values.length,
    calldataSelector: calldata.values[0]!.toString(),
    // The snapshot taken BEFORE the control's deliberate touch, so the control cannot make this
    // list non-empty and the two facts stay independent.
    merkleTouches: observedDuringBuild,
    merkleTripwireControl: tripwireControl,
    merkleTouchesAfterControl: touchesAfterControl,
    registeredClasses: (await dataSource.getContractClass(contractClass.id)) !== undefined ? 1 : 0,
    registeredInstances:
      (await dataSource.getContract(contractInstance.address)) !== undefined ? 1 : 0,
    dispatchBytecodeBase64: rawDispatch.bytecode,
    dispatchDebugSymbolsBase64: rawDispatch.debug_symbols,
    fileMap: raw.file_map ?? {},
  };
}

/**
 * Exercise `trace_join.ts` — the grammar round trip, and every refusal by name.
 *
 * Executed rather than reasoned about, and the acceptance arm is here for the reason every refusal
 * suite needs one: a joiner that refused EVERYTHING would satisfy all seven refusals.
 */
export function exerciseTraceJoin(joinId: string): Record<string, unknown> {
  const canonical = joinRecord(joinId, 'private', 2, 'split');
  const rendered = formatJoinRecord(canonical);
  const reparsed = parseJoinRecord(rendered);

  const half = (label: string, record: ReturnType<typeof joinRecord> | undefined): HalfRecording => ({
    label,
    container: new Uint8Array(1),
    record,
  });
  const refusal = (halves: HalfRecording[]): string => {
    try {
      joinRecordings(halves);
      return 'accepted';
    } catch (e) {
      return e instanceof TraceJoinRefused ? e.ground : `other:${(e as Error).name}`;
    }
  };

  const good = [
    half('private', joinRecord(joinId, 'private', 2, 'split')),
    half('public', joinRecord(joinId, 'public', 2, 'split')),
  ];
  let acceptedOrder: string;
  try {
    acceptedOrder = joinRecordings(good).order.join(',');
  } catch (e) {
    acceptedOrder = `REFUSED:${(e as Error).message}`;
  }
  let sharedOrder: string;
  try {
    sharedOrder = joinRecordings([half('both', joinRecord(joinId, 'both', 1, 'shared'))]).order.join(',');
  } catch (e) {
    sharedOrder = `REFUSED:${(e as Error).message}`;
  }

  return {
    metadataKey: JOIN_EVENT_METADATA,
    reason: JOIN_REASON,
    rendered,
    reparsedMatches: reparsed !== undefined && formatJoinRecord(reparsed) === rendered,
    parseRejectsGarbage: parseJoinRecord('not a join record at all') === undefined,
    parseRejectsMissingField: parseJoinRecord('join=x half=private arm=split reason=r') === undefined,
    parseRejectsBadHalf: parseJoinRecord('join=x half=middle halves=2 arm=split reason=r') === undefined,
    parseRejectsBadArm: parseJoinRecord('join=x half=private halves=2 arm=guessed reason=r') === undefined,
    parseRejectsBadCount: parseJoinRecord('join=x half=private halves=0 arm=split reason=r') === undefined,
    acceptedOrder,
    sharedOrder,
    refusals: {
      empty: refusal([]),
      unrecorded: refusal([good[0]!, half('public', undefined)]),
      identityMismatch: refusal([
        good[0]!,
        half('public', joinRecord('a-different-join', 'public', 2, 'split')),
      ]),
      countMismatch: refusal([good[0]!]),
      declaredCountMismatch: refusal([
        half('private', joinRecord(joinId, 'private', 3, 'split')),
        half('public', joinRecord(joinId, 'public', 3, 'split')),
      ]),
      duplicateHalf: refusal([good[0]!, half('public2', joinRecord(joinId, 'private', 2, 'split'))]),
      armMismatch: refusal([good[0]!, half('public', joinRecord(joinId, 'public', 2, 'shared'))]),
    },
  };
}

/**
 * Put the join on a transaction's PROVENANCE — M26's `TxProvenance.privateTrace` deliverable.
 *
 * DD-1 is what makes this the right place for it and the wrong place for the recording itself.
 * Provenance is metadata ALONGSIDE the transaction and must not reach execution, so what travels
 * with the transaction is a HANDLE naming the join, not a container and not a path. M20's
 * provenance seal traps every read of this object during the execution window, so a consumer reads
 * it before entering that window or not at all — and there is nothing in it worth branching on.
 *
 * The summary is M21's `PrivateExecutionSummary` and is filled in from what was actually traced,
 * which is why `nestedCalls` and `publicCalls` are parameters rather than constants: a placeholder
 * would put a fabricated value in a field a consumer reads, which is the reason M21 made
 * `privateExecution` required on THIS return type in the first place.
 */
export function traceJoinedTx<T>(
  tx: T,
  opts: {
    joinId: string;
    halves: number;
    arm: JoinArm;
    contract: string;
    selector: string;
    nestedCalls: number;
    publicCalls: number;
    simulator: string;
  },
): ReturnType<typeof locallyExecutedTx<T>> {
  const record = joinRecord(opts.joinId, opts.halves === 1 ? 'both' : 'private', opts.halves, opts.arm);
  return locallyExecutedTx(
    tx,
    {
      contract: opts.contract,
      selector: opts.selector,
      nestedCalls: opts.nestedCalls,
      publicCalls: opts.publicCalls,
      simulator: opts.simulator,
    },
    privateTraceHandleFor(record),
  );
}
