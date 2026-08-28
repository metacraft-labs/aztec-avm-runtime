// `aztec-avm-runtime/testing` — DD-5's test-harness entry point.
//
// "adds `FakeClock`, fixture builders, and the recovered `PublicTxSimulationTester` shape;
// `intervalMs: 0` + explicit `produceBlock()` gives deterministic tests."
//
// IT ADDS NO CAPABILITY THE BROWSER ENTRY LACKS, and that is not a slogan — everything below runs
// in a page, and `smoke_browser_token_transfer` proves it by running `runTokenTransfer` IN one.
// What it adds is DETERMINISM: upstream's `ManualDateProvider` and this repository's `ManualTicker`
// are already public exports of the browser entry, so what is genuinely new here is the fixture
// builder and the writer-side demo recorder.
//
// THE FIXTURE BUILDER IS M26'S VENDORED UPSTREAM ONE, not a fixture of ours. `PublicTxSimulationTester`
// is `orchestration/src/vendor/public_tx_simulation_tester.ts`, vendored from the `ts` anchor and
// registered in `PROVENANCE.md` (F20–F24) with `just check-drift` comparing it against that commit
// on every run. The design document asked for "the recovered `PublicTxSimulationTester` shape" and
// what is here is the shape itself rather than a recovery of it.
//
// WHY IT IS A SEPARATE ENTRY POINT AND NOT A FLAG. A flag would put the tester — and the 7 MB
// contract artifact its callers fetch — in the browser entry's module graph, where M28's leakage
// check would then find it. Three entry points is what keeps "test-only" a fact about the graph.

export * from './entry_browser.ts';

// ---- deterministic fixtures -------------------------------------------------------------------
export {
  BALANCE_FUNCTION,
  DEMO_FUNDING,
  DEMO_TOKEN_BALANCE,
  DEMO_TRANSFER_AMOUNT,
  TRANSFER_FUNCTION,
  runTokenTransfer,
  storageSlotOf,
  type TokenTransferReport,
} from './token_transfer.ts';

// ---- upstream's own builder, vendored ---------------------------------------------------------
export {
  createContractClassAndInstance,
  getContractFunctionAbi,
  getFunctionSelector,
} from '../../orchestration/src/vendor/avm_fixtures_utils.ts';
export { PublicTxSimulationTester } from '../../orchestration/src/vendor/public_tx_simulation_tester.ts';
export { SimpleContractDataSource } from '../../orchestration/src/vendor/simple_contract_data_source.ts';

// ---- the recorder, with the download suppressible so a probe can read the bytes ---------------
export { base64ToBytes, inflateRaw, offerDownload } from './ct_download.ts';
