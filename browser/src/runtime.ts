// Opening a runtime in a browser: one fetch, one instantiation, one facade.
//
// THE WORLD-BUILDING IS THE NODE DRIVERS' AND IS DELIBERATELY THE SAME SHAPE. `openWorld` in
// `orchestration/src/chain_e2e_driver.ts` is the reference; the classes it composes —
// `ResidentMerkleWriteOperations`, `ResidentContractsDB`, `ResidentMerkleDb`,
// `WasmAvmPublicTxSimulator`, `createBlockProcessor`, `AvmChain`, `AvmRuntime` — are all public
// exports of `@aztec-avm-runtime/orchestration` and NONE of them imports a Node builtin. That is
// the M23 deliverable "everything it adds is browser-shaped by construction" cashed out: this file
// is short because the work was done there.
//
// WHAT IS BROWSER-SPECIFIC IS EXACTLY THREE THINGS, and each is one line:
//   1. the module arrives over `fetch` instead of `readFile`;
//   2. WASI comes from `createBrowserWasi` instead of `node:wasi`;
//   3. poseidon2 comes from the module instead of from bb.js (DD-11 — see `poseidon.ts`).
//
// DD-4: THE CLOCK IS AN ARGUMENT. `AvmChain` has taken one since M23 and this does not weaken it —
// `openAvmRuntime` requires a `DateProvider` and passes it down. The WASI shim gets one too, which
// is a place M23 could not reach because M23 had no WASI of its own.

import { Fr } from '@aztec/foundation/curves/bn254';
import { GasFees } from '@aztec/stdlib/gas';
import { GlobalVariables } from '@aztec/stdlib/tx';
import { serializeWithMessagePack } from '@aztec/stdlib/avm';

import {
  AvmChain,
  AvmRuntime,
  DateProvider,
  ResidentContractsDB,
  ResidentMerkleDb,
  ResidentMerkleWriteOperations,
  WasmAvmPublicTxSimulator,
  createBlockProcessor,
  decodePublicTxResult,
  defaultPublicSimulatorConfig,
  encodeForShippedModuleOnly,
  residentWorldStateRevision,
  type BlockProductionConfig,
} from '../../orchestration/src/index.ts';

import { compileAvmFromUrl, instantiateAvm, type CompiledAvm } from './loader.ts';
import { createAvmPoseidon2, installPoseidon2, type Poseidon2Backend } from './poseidon.ts';
import { createAvmGrumpkin, installGrumpkin, type GrumpkinBackend } from './grumpkin.ts';
import type { Reactor } from '../../node-host/src/reactor.ts';
import type { BrowserWasi } from './wasi.ts';

export interface OpenOptions {
  /** Where `avm.wasm` is. Relative URLs are resolved by the page, which is what makes it lazy. */
  readonly moduleUrl: string;
  /** DD-4. Upstream's `DateProvider`, `TestDateProvider` or `ManualDateProvider`. Required. */
  readonly clock: DateProvider;
  /** Block production. Defaults to the chain's own default. */
  readonly production?: BlockProductionConfig;
  /** Where the §8.4 disclosure line goes. Defaults to `console.warn`, as in Node. */
  readonly disclosureSink?: (line: string) => void;
  /** Where the module's own `vinfo` logging goes. A browser has no stderr. */
  readonly writeLine?: (fd: number, line: string) => void;
  /** Injected `fetch`, so a page can wrap it and a test can count requests without a global. */
  readonly fetch?: typeof globalThis.fetch;
  /** L2 gas fees for the arm's global variables. Defaults to 1/1, as the Node drivers use. */
  readonly gasFees?: GasFees;
}

export interface OpenedRuntime {
  readonly runtime: AvmRuntime;
  readonly chain: AvmChain;
  readonly reactor: Reactor;
  readonly wasi: BrowserWasi;
  readonly compiled: CompiledAvm;
  readonly poseidon: Poseidon2Backend;
  /** DD-11's other half: the curve, from the same module. See `grumpkin.ts`. */
  readonly grumpkin: GrumpkinBackend;
  readonly merkleDb: ResidentMerkleWriteOperations;
  readonly contractsDb: ResidentContractsDB;
  readonly publicDataTree: ResidentMerkleDb;
  readonly simulator: WasmAvmPublicTxSimulator;
  /** Releases the module's DB handles. The instance itself is reclaimed by the collector. */
  close(): Promise<void>;
}

/**
 * Fetch `avm.wasm`, instantiate it, and stand a runtime on it.
 *
 * ONE NETWORK REQUEST IS MADE HERE AND `verify_public_only_page_never_fetches_barretenberg`
 * asserts on the browser's own log that it is the only one this path makes.
 */
export async function openAvmRuntime(options: OpenOptions): Promise<OpenedRuntime> {
  const compiled = await compileAvmFromUrl(options.moduleUrl, {
    ...(options.fetch ? { fetch: options.fetch } : {}),
  });
  const { reactor, wasi } = await instantiateAvm(compiled, {
    nowMs: () => options.clock.now(),
    ...(options.writeLine ? { writeLine: options.writeLine } : {}),
  });

  // BEFORE ANYTHING HASHES OR DERIVES AN ADDRESS. `installPoseidon2` has to happen before the first `poseidon2Hash`,
  // and the first one is inside `fundFeeJuice`. There is deliberately no lazy fallback to bb.js —
  // see `poseidon.ts` — so getting the order wrong is a loud `Poseidon2NotInstalled` rather than a
  // 7.9 MB download nobody notices.
  const poseidon = createAvmPoseidon2(reactor, (fields) => serializeWithMessagePack(fields));
  installPoseidon2(poseidon);
  const grumpkin = createAvmGrumpkin(reactor, (args) => serializeWithMessagePack(args));
  installGrumpkin(grumpkin);

  const contractDbHandle = reactor.createContractDb();
  const merkleDbHandle = reactor.createMerkleDb();
  const merkleDb = new ResidentMerkleWriteOperations(reactor, merkleDbHandle);
  const contractsDb = new ResidentContractsDB(reactor, contractDbHandle);
  const publicDataTree = new ResidentMerkleDb(reactor, merkleDbHandle);
  const config = defaultPublicSimulatorConfig();
  const globals = GlobalVariables.from({
    ...GlobalVariables.empty(),
    gasFees: options.gasFees ?? new GasFees(1n, 1n),
  });
  const simulator = new WasmAvmPublicTxSimulator(
    {
      simulate: (input, c, m) => reactor.simulate(input, c, m),
      get moduleCalls() {
        return reactor.moduleCalls;
      },
    },
    { contractDb: contractDbHandle, merkleDb: merkleDbHandle },
    globals,
    (t, g) => encodeForShippedModuleOnly(t, g, config, residentWorldStateRevision(1)),
    () => decodePublicTxResult(reactor.result()!),
  );

  const runtime = AvmRuntime.create(
    {
      merkleDb,
      contractsDb,
      makeProcessor: (g: GlobalVariables) =>
        createBlockProcessor(g, merkleDb, contractsDb, simulator, options.clock),
      clock: options.clock,
      simulator,
      publicDataTree,
    } as never,
    {
      ...(options.production ? { production: options.production } : {}),
      ...(options.disclosureSink ? { disclosureSink: options.disclosureSink } : {}),
    },
  );

  return {
    runtime,
    chain: runtime.chain,
    reactor,
    wasi,
    compiled,
    poseidon,
    grumpkin,
    merkleDb,
    contractsDb,
    publicDataTree,
    simulator,
    async close() {
      await runtime.stop();
      reactor.destroyMerkleDb(merkleDbHandle);
      reactor.destroyContractDb(contractDbHandle);
    },
  };
}

export { Fr };
