// The demo page.
//
// M27's deliverable: "a demo page executing a transaction, producing a block on a real timer, and
// offering the `.ct` container for download".
//
// ===========================================================================================
// IT IS BOTH THE DEMO AND THE HARNESS, AND THAT IS DELIBERATE.
// ===========================================================================================
//
// Everything the headless checks drive is a BUTTON on this page. `tools/run_browser_arms.mjs`
// calls `window.avmDemo.<arm>()` over the DevTools protocol, and a person clicks the same
// functions. There is no test-only code path into the runtime, so "the demo works" and "the checks
// pass" cannot come apart — which is the failure mode of every demo page that has a separate
// automation entry point.
//
// ===========================================================================================
// `loadProvingStack` IS A NEGATIVE CONTROL AND IT IS NOT PART OF THE PRODUCT.
// ===========================================================================================
//
// `verify_public_only_page_never_fetches_barretenberg` asserts an ABSENCE from a network log, and
// an absence measured by an instrument that has never seen the thing is worth nothing —
// `CAMPAIGN-BRIEF.md` records two shipped defects of exactly that shape ("an absence asked of a
// tree that excludes the subject by construction"). So this page carries one function whose entire
// purpose is to make barretenberg's wasm appear in the log, and the check runs it in a SECOND page
// and requires the request to be there. If the substitution ever stopped working, the first arm
// would go red; if the observation ever stopped working, the second would.
//
// It is in the DEMO and not in `entry_browser.ts`, so the reference entry point's module graph does
// not contain a deliberate call into the proving stack.

import {
  DateProvider,
  openAvmRuntime,
  runTokenTransfer,
  recordAndDownload,
  fetchCtWriter,
  type ChainBlock,
  type OpenedRuntime,
  type TokenTransferReport,
} from '../src/entry_testing.ts';

const MODULE_URL = './assets/avm.wasm';
const CT_WRITER_URL = './assets/ct_writer.wasm';
const ARTIFACT_URL = './assets/token_contract-Token.json';

// A UUID. `ct-print` refuses a `recording_id` that is not exactly 36 characters — measured in M26,
// which is why this is a well-formed id and not a readable label.
const RECORDING_ID = '01949fcc-7d92-7e9c-8000-000000002701';

const log: string[] = [];
function say(line: string): void {
  log.push(line);
  const el = document.getElementById('log');
  if (el) el.textContent = log.join('\n');
}

const wasiLines: string[] = [];

let opened: OpenedRuntime | null = null;
let atOpen: Record<string, unknown> | null = null;
let artifact: unknown = null;
let transfer: TokenTransferReport | null = null;

async function open(production?: { intervalMs: number; minBlockSpacingSeconds?: number }): Promise<OpenedRuntime> {
  if (opened) return opened;
  const clock = new DateProvider();
  opened = await openAvmRuntime({
    moduleUrl: MODULE_URL,
    clock,
    ...(production ? { production: production as never } : {}),
    disclosureSink: (line: string) => say(`[disclosure] ${line}`),
    writeLine: (fd: number, line: string) => {
      wasiLines.push(`${fd}:${line}`);
    },
  });
  say(`avm.wasm: ${opened.compiled.byteLength} bytes, ${opened.compiled.declaredImports.length} imports, ` +
    `${opened.reactor.exportNames.length} exports, streaming=${opened.compiled.streaming}`);
  // A SNAPSHOT TAKEN BEFORE ANY WORK. `random_get` is called exactly once and it is called HERE,
  // during `_initialize`; without this snapshot the single call would be indistinguishable from a
  // call the AVM made while executing, which is a different fact about determinism.
  atOpen = {
    wasiCalls: { ...opened.wasi.calls },
    declaredImports: [...opened.compiled.declaredImports],
    exports: opened.reactor.exportNames.length,
    moduleBytes: opened.compiled.byteLength,
    streaming: opened.compiled.streaming,
    memoryPages: opened.reactor.pages,
  };
  return opened;
}

async function loadArtifact(): Promise<unknown> {
  if (artifact) return artifact;
  const response = await fetch(ARTIFACT_URL);
  if (!response.ok) throw new Error(`${ARTIFACT_URL}: ${response.status}`);
  artifact = await response.json();
  return artifact;
}

// ---------------------------------------------------------------------------------------------
// ARM: a token transfer. Real calldata, ABI-derived selector, a registered contract, a real block.
// ---------------------------------------------------------------------------------------------
async function armTokenTransfer(): Promise<Record<string, unknown>> {
  const o = await open({ intervalMs: 0, minBlockSpacingSeconds: 1 });
  const report = await runTokenTransfer(o, await loadArtifact());
  transfer = report;
  say(`${report.artifactName}.${report.debugFunctionNames[0] ?? '?'} -> ${report.outcome} in block ${report.blockNumber}`);
  return {
    ...report,
    poseidonInstalled: o.poseidon.calls > 0,
    atOpen,
    wasiCalls: { ...o.wasi.calls },
    moduleGuestLines: wasiLines.length,
  };
}

// ---------------------------------------------------------------------------------------------
// ARM: blocks on a REAL timer, across a freeze.
//
// The chain runs on `RunningPromiseTicker`, which sleeps against the host's timers — upstream's
// `RunningPromise`, not a fake. The harness FREEZES the page in the middle
// (`Page.setWebLifecycleState`), which is what a backgrounded tab does to a timer, and this arm
// reports every block it saw either side of the gap. The monotonicity rule is
// `timestamp = max(prev + minBlockSpacingSeconds, floor(clock.nowMs() / 1000))` and the point of
// the freeze is that it exercises the SECOND branch after the first has been holding.
// ---------------------------------------------------------------------------------------------
async function armRealTimer(options: { intervalMs?: number; blocks?: number } = {}): Promise<Record<string, unknown>> {
  const intervalMs = options.intervalMs ?? 250;
  const want = options.blocks ?? 4;
  await startTicking(intervalMs);
  const startedAt = performance.now();
  while (seen.length < want && performance.now() - startedAt < 30_000) {
    await new Promise<void>((resolve) => {
      const check = () => (seen.length >= want ? resolve() : requestAnimationFrame(check));
      check();
    });
  }
  return { intervalMs, ...(await stopTicking()) };
}

/** Blocks seen so far, so the harness can read them either side of a freeze without stopping. */
const seen: ChainBlock[] = [];
let watching: (() => void) | null = null;

async function startTicking(intervalMs: number): Promise<Record<string, unknown>> {
  const o = await open({ intervalMs, minBlockSpacingSeconds: 1 });
  if (!watching) {
    watching = o.runtime.subscribe('block', (b: ChainBlock) => {
      seen.push(b);
    });
  }
  o.runtime.start();
  return { intervalMs, started: true, visibility: document.visibilityState };
}

async function stopTicking(): Promise<Record<string, unknown>> {
  const o = await open();
  await o.runtime.stop();
  watching?.();
  watching = null;
  return {
    blocks: seen.map((b) => ({
      number: b.number,
      timestamp: b.timestamp.toString(),
      wallClockSeconds: b.wallClockSeconds.toString(),
      wallClockDeviationSeconds: b.wallClockDeviationSeconds.toString(),
      empty: b.empty,
    })),
  };
}

// ---------------------------------------------------------------------------------------------
// ARM: the `.ct` container, offered for download. THE PRODUCT CLAIM.
// ---------------------------------------------------------------------------------------------
async function armRecord(options: { download?: boolean } = {}): Promise<Record<string, unknown>> {
  const o = await open();
  if (!transfer) await armTokenTransfer();
  const raw = await loadArtifact();
  const writerBytes = await fetchCtWriter(CT_WRITER_URL);
  const addressHex = transfer!.contractAddress.replace(/^0x/, '').padStart(64, '0');
  const address = new Uint8Array(32);
  for (let i = 0; i < 32; i++) address[i] = parseInt(addressHex.slice(i * 2, i * 2 + 2), 16);
  const recording = await recordAndDownload({
    writerBytes,
    rawArtifact: raw,
    contractAddress: address,
    frameNames: transfer!.debugFunctionNames,
    recordingId: RECORDING_ID,
    ...(options.download === false ? { download: false } : {}),
  });
  say(`.ct container: ${recording.bytes} bytes, ${recording.events} events, rung ${recording.rung}`);
  const { container, ...rest } = recording;
  return { ...rest, containerBase64: bytesToBase64(container) };
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

// ---------------------------------------------------------------------------------------------
// THE NEGATIVE CONTROL. Not a feature. See the header.
// ---------------------------------------------------------------------------------------------
async function loadProvingStack(): Promise<Record<string, unknown>> {
  const bb = await import('@aztec/bb.js');
  await bb.BarretenbergSync.initSingleton();
  const api = bb.BarretenbergSync.getSingleton();
  const out = api.poseidon2Hash({ inputs: [new Uint8Array(32), new Uint8Array(32)] });
  say('[negative control] barretenberg fetched and initialised');
  return { fetched: true, hashBytes: out.hash.length };
}

const api = {
  armTokenTransfer,
  armRealTimer,
  armRecord,
  startTicking,
  stopTicking,
  loadProvingStack,
  atOpen: () => atOpen,
  status: () => ({
    opened: opened !== null,
    moduleBytes: opened?.compiled.byteLength ?? null,
    poseidonCalls: opened?.poseidon.calls ?? null,
    visibility: document.visibilityState,
    log: [...log],
    wasiLines: wasiLines.slice(0, 20),
  }),
};

declare global {
  // eslint-disable-next-line no-var
  var avmDemo: typeof api;
  // eslint-disable-next-line no-var
  var avmDemoReady: boolean;
}

globalThis.avmDemo = api;
globalThis.avmDemoReady = true;
say('demo ready');

// Wire the buttons. A person clicks these; the harness calls the same functions.
for (const [id, fn] of Object.entries({
  'btn-transfer': armTokenTransfer,
  'btn-timer': () => armRealTimer(),
  'btn-record': () => armRecord(),
  'btn-proving': loadProvingStack,
})) {
  document.getElementById(id)?.addEventListener('click', () => {
    (fn as () => Promise<unknown>)().catch((e: unknown) => say(`ERROR ${String(e)}`));
  });
}
