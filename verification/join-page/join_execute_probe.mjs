// join_execute_probe.mjs — register, execute and TRACE the contract the tab compiled.
//
// Stage 1 (`join_node_probe.mjs` / the page) produced a transpiled `SimpleToken` from a compile
// that happened in Chromium. This takes THAT ARTIFACT — read from the file the page wrote, not
// recompiled here — and runs the rest of the chain:
//
//   REGISTER   class + instance into the module's resident contract DB
//   SEED       the five things without which the transaction reverts, each derived from THIS
//              artifact rather than from a constant
//   EXECUTE    a real transaction through `avm.wasm`, in a block
//   TRACE      the executed step stream into a `.ct` container via `ct_writer.wasm`
//
// WHY THIS RUNS IN NODE AND SAYS SO. `test_transpiled_contract_registers_and_executes` draws the
// same boundary and states it: the browser half is measured in a browser and the execution half
// is not. What is new here is not the host — it is that the bytes being registered were COMPILED
// in a tab, which no previous check has done. The provenance string carries that distinction into
// the report so a reader cannot come away thinking otherwise.
//
// Run:
//   AVM_WASM_PATH=<avm.wasm> CT_WRITER_WASM=<ct_writer.wasm> \
//   JOIN_ARTIFACT=<browser-transpiled.json> node --experimental-strip-types join_execute_probe.mjs

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash, randomBytes } from 'node:crypto';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const artifactPath = process.env.JOIN_ARTIFACT;
const avmWasm = process.env.AVM_WASM_PATH;
const writerWasm = process.env.CT_WRITER_WASM;
for (const [n, v] of [['JOIN_ARTIFACT', artifactPath], ['AVM_WASM_PATH', avmWasm],
  ['CT_WRITER_WASM', writerWasm]]) {
  if (!v || !existsSync(v)) {
    console.error(`SKIP: ${n} is unset or missing (${v}). This is a skip, not a pass.`);
    process.exit(2);
  }
}

const here = path.dirname(new URL(import.meta.url).pathname);
const repoRoot = path.resolve(here, '..', '..');
const mod = (p) => import(pathToFileURL(path.join(repoRoot, p)).href);

const { openAvmRuntime } = await mod('browser/src/runtime.ts');
const { runTokenTransfer } = await mod('browser/src/token_transfer.ts');
const { recordAndDownload } = await mod('browser/src/ct_download.ts');
const { ManualDateProvider } = await mod('orchestration/src/chain_clock.ts');

const bytes = readFileSync(artifactPath);
const sha = createHash('sha256').update(bytes).digest('hex');
const artifact = JSON.parse(bytes.toString('utf8'));

/**
 * ONE NAMED SHAPE ADAPTER, AND IT IS A FINDING RATHER THAN A FIX.
 *
 * `@aztec/stdlib`'s `getStorageLayout` reads `outputs.globals.storage[i].fields`, and
 * `ContractArtifactSchema` requires each entry to carry a `kind` discriminator. The artifact this
 * compiler produces wraps every comptime global as `{name: 'STORAGE_LAYOUT_<C>', value: {kind,
 * fields}}` — Noir's rendering became a list of NAMED values between the version
 * `@aztec/stdlib@5.0.0-nightly.20260626` was written against and `metacraft-labs/noir@9d4e40a6`,
 * which is what the tab compiles with. The old shape is exactly the inner value.
 *
 * Without this, `loadContractArtifact` throws
 *   `Could not generate contract artifact for SimpleToken: TypeError: Cannot read properties of
 *    undefined (reading 'find')`
 * which names neither the field nor the versions, and is the whole reason this is lifted here
 * where it can be described instead of inside a stack trace.
 *
 * IT IS APPLIED TO A COPY AND COUNTED. The count is reported, so "no adaptation was needed" and
 * "the adapter silently did nothing" are distinguishable — an adapter that stopped matching
 * would otherwise look like a compatibility that had arrived.
 */
function adaptStorageGlobals(input) {
  const copy = JSON.parse(JSON.stringify(input));
  const storage = copy?.outputs?.globals?.storage;
  let lifted = 0;
  if (Array.isArray(storage)) {
    for (const entry of [...storage]) {
      // The whole ENTRY gained the wrapper, not just its fields: what used to be
      // `{kind: 'struct', fields: [...]}` is now `{name: 'STORAGE_LAYOUT_<C>', value: {kind,
      // fields}}`. So the old shape is exactly the inner value, and unwrapping is the adaptation.
      // Lifting only `fields` was the first attempt and `ContractArtifactSchema` rejected it on
      // the missing `kind` discriminator, which is the schema doing its job.
      if (entry && entry.kind === undefined && entry.value && entry.value.kind !== undefined) {
        storage[storage.indexOf(entry)] = entry.value;
        lifted += 1;
      }
    }
  }
  return { artifact: copy, lifted };
}

const adapted = adaptStorageGlobals(artifact);
console.log(`  storage-globals adapter lifted ${adapted.lifted} entry(ies) ` +
  `(0 would mean the shapes already agree)`);

/**
 * A UUIDv7. `ct-print` REFUSES a v4 — "expected version nibble '7' at position 14, got '4'" — and
 * it says so while exiting 0, so a probe that trusted the status would have recorded a container
 * no reader accepts as a success.
 */
function uuidV7() {
  const b = randomBytes(16);
  const ms = BigInt(Date.now());
  for (let i = 0; i < 6; i++) b[i] = Number((ms >> BigInt(8 * (5 - i))) & 0xffn);
  b[6] = (b[6] & 0x0f) | 0x70;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

let failures = 0;
const ok = (m) => console.log(`  [OK]     ${m}`);
const bad = (m) => { console.log(`  [FAILED] ${m}`); failures++; };

console.log('=== register + execute + trace, on a contract COMPILED IN A TAB ===');
console.log(`  artifact ${artifact.name}, ${artifact.functions.length} functions, ` +
  `${bytes.length} bytes, sha256 ${sha.slice(0, 32)}`);

// A `fetch` over the local filesystem: `openAvmRuntime` takes one so a page can wrap it, and that
// is exactly what makes the same function usable from Node without a second loader.
const fileFetch = async (url) => {
  const p = String(url).startsWith('file://') ? new URL(String(url)).pathname : String(url);
  const b = readFileSync(p);
  return { ok: true, status: 200, headers: { get: () => 'application/wasm' },
    arrayBuffer: async () => b.buffer.slice(b.byteOffset, b.byteOffset + b.length) };
};

const opened = await openAvmRuntime({
  moduleUrl: pathToFileURL(avmWasm).href,
  clock: new ManualDateProvider(0),
  fetch: fileFetch,
  // WITHOUT THIS THERE IS NO TRACE, and `recordAndDownload` refuses by name rather than writing a
  // container with nothing in it. `steps.last` would be `null`, which is a different statement
  // from an empty stream.
  collectExecutionSteps: true,
  disclosureSink: () => {},
  writeLine: () => {},
});
ok('avm.wasm instantiated (env.memory + 12 WASI imports + _initialize)');

let report;
try {
  report = await runTokenTransfer(opened, adapted.artifact, {
    // Read off the artifact above, not guessed: this SimpleToken is built against a later
    // aztec-nr whose macros prefix the generated entry points.
    transferFunction: '__aztec_nr_internals__public_transfer',
    balanceFunction: '__aztec_nr_internals__public_balance_of',
    constructorFunction: '__aztec_nr_internals__constructor',
    constructorArgs: ['Tok', 'TOK', 18],
    // `public_balances` (slot 3), NOT `balances` (slot 1). `balances` is the PRIVATE note set —
    // `Owned<BalanceSet>` — and seeding it produced a transaction that read 1000 back through the
    // same derivation that wrote it and still reverted at 374 steps. A self-consistent read is not
    // evidence: the contract reads slot 3. This is the driver's default, and overriding it was the
    // mistake; the name is kept explicit here because getting it from a truncated storage listing
    // is exactly how it went wrong.
    balancesStorageMember: 'public_balances',
  });
} catch (err) {
  bad(`the transfer driver threw: ${String(err && err.message ? err.message : err)}`);
  console.log(String(err && err.stack).slice(0, 2500));
  await opened.close();
  process.exit(1);
}

console.log(`\n  EXECUTE  outcome=${report.outcome} revertCode=${report.revertCode} ` +
  `block=${report.blockNumber} enqueued=${report.enqueuedPublicCalls}`);
if (report.revertDescription) console.log(`           revert: ${report.revertDescription}`);
if (report.revertReason) console.log(`           reason: ${String(report.revertReason).slice(0, 300)}`);

// ---- the assertions that separate "it ran" from "it reported ok" -------------------------
if (report.registeredClasses >= 1 && report.registeredInstances >= 1) {
  ok(`REGISTER: ${report.registeredClasses} class, ${report.registeredInstances} instance`);
} else {
  bad(`nothing was registered: ${report.registeredClasses}/${report.registeredInstances}`);
}
// `revertCode 0` is the claim; `outcome: processed` is NOT, because a block processes a
// reverting transaction perfectly happily. M29's defect was exactly this conflation.
if (report.revertCode === 0) ok('revertCode is 0 — the transaction did not revert');
else bad(`revertCode is ${report.revertCode} — the transaction REVERTED`);

// The instruction count lives on the RECORDING, not on this report — `TokenTransferReport` has
// no such field, and reading one off it printed `undefined` next to a green tick until the
// container's own counter was used instead. 1 is M29's signature for `read_instruction` throwing
// before the opcode was known.
const executedCount = opened.steps.last ? opened.steps.last.count : 0;
if (executedCount > 1) {
  ok(`the AVM executed ${executedCount} instructions (1 is the revert-at-pc-0 signature)`);
} else {
  bad(`the AVM executed ${executedCount} instructions`);
}

const executed = opened.steps.last;
if (executed && executed.steps.length > 0) {
  ok(`the step stream drained ${executed.steps.length} steps in ${executed.crossings} crossing(s)`);
} else {
  bad('the step stream is empty or unavailable');
}
if (executed && executed.count === executed.steps.length) {
  ok(`and the module's own count agrees: ${executed.count}`);
} else {
  bad(`module count ${executed && executed.count} != decoded ${executed && executed.steps.length}`);
}

// ---- TRACE --------------------------------------------------------------------------------
let recording;
try {
  recording = await recordAndDownload({
    writerBytes: new Uint8Array(readFileSync(writerWasm)),
    rawArtifact: adapted.artifact,
    contractAddress: Buffer.from(String(report.contractAddress).replace(/^0x/, ''), 'hex'),
    frameNames: [report.debugFunctionName, undefined],
    recordingId: uuidV7(),
    executed,
    download: false,
    extraLogEvents: [{
      metadata: 'ct.bytecode-provenance',
      content: 'compiled by noir_wasm.wasm and transpiled by avm_transpiler_wasm.wasm inside '
        + `Chromium; artifact sha256 ${sha}`,
    }],
  });
} catch (err) {
  bad(`recording refused: ${String(err && err.message ? err.message : err)}`);
  await opened.close();
  process.exit(1);
}

console.log(`\n  TRACE    ${recording.bytes} container bytes, ${recording.events} events, ` +
  `${recording.executedSteps} steps, rung ${recording.rung} (declared ${recording.declaredRung}), ` +
  `${recording.stepsPositioned} positioned / ${recording.stepsUnpositioned} unpositioned, ` +
  `${recording.distinctOpcodes} distinct opcodes`);

if (recording.container.length > 0) ok(`a .ct container of ${recording.container.length} bytes`);
else bad('the container is empty');
// THE FALSE PASS THIS CAMPAIGN KEEPS MEETING: a trace that exists with zero steps while every
// call reports ok. Asserted on the container's own counter, not on the drain.
if (recording.events > 1 && recording.executedSteps > 0) {
  ok(`with ${recording.events} events over ${recording.executedSteps} executed steps`);
} else {
  bad(`ONE-EVENT-ZERO-STEPS: ${recording.events} events, ${recording.executedSteps} steps — ` +
      'the false pass an uninstrumented artifact produces');
}

if (process.env.JOIN_CT_OUT) {
  writeFileSync(process.env.JOIN_CT_OUT, Buffer.from(recording.container));
  console.log(`  wrote the container to ${process.env.JOIN_CT_OUT}`);
}

await opened.close();
console.log(failures === 0
  ? '\nRESULT: OK — a tab-compiled contract registered, executed and was traced'
  : `\nRESULT: FAILED — ${failures} check(s)`);
process.exit(failures === 0 ? 0 : 1);
