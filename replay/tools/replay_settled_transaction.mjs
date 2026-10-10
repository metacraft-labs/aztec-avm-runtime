#!/usr/bin/env node
// replay_settled_transaction.mjs — L2's driver: a settled transaction, re-executed.
//
// TWO MODES, AND THE SECOND IS WHY THE FIRST EXISTS.
//
//   --fixture <path>   play a recording back. NO NETWORK. This is the mode the checks run in.
//   --url <rpc> --capture <path>
//                      drive a LIVE node through `recordingFetch` and write the recording, so that
//                      every node call the replay made — including the per-slot hydration reads —
//                      is in the fixture and the check that comes after it is offline.
//
// AND ONE INPUT THAT IS NEITHER A MODE NOR A MOCK:
//
//   --body-store auto|<base>   answer `getTxByHash` from Aztec's published `TxFileStore` instead of
//                              from the node's mempool, which is the ONE call that has a horizon.
//                              `auto` reads the base from the published network config. Everything
//                              else still comes from the node. `--body-file <path>` is the same
//                              join with a body already on disk.
//
// WHAT THAT UNLOCKS, MEASURED ON MAINNET 2026-10-10: transaction
// 0x00c67f6f…753ed18d settled in block 68062 and the chain tip was 118225 — 50,163 blocks past the
// mempool's horizon, `getTxByHash` answering null. With the store joined in, the replay reproduced
// the corpus's own frozen row EXACTLY: 2 hydration rounds, 1 nullifier + 2 public-data leaves
// seeded, 208 instructions, 13/13 published effects matched, the same six skipped values with the
// same reasons, the same four tree-root pairs. The SAME run on 0x0f191b2d…e8699dbb (block 68231):
// 338 instructions, 20/20 matched. COST: 8 JSON-RPC requests and ONE store GET per transaction, of
// which the `getNodeInfo` is once per deployment and not per transaction.
//
// SO THE HISTORY IS NOT FROZEN. The corpus's containers are CTFS version 3 and the reader at
// `pins.json`'s `trace_format_nim` anchor refuses them by name ("this reader reads version 5 only.
// Re-record"); the re-recording above writes version 5 with a `meta.dat` v6 header, and both
// `ct-print` and `ct-split-probe` at that anchor open it and read every stream.
//
// The capture mode is the only honest way to build the fixture. L1's capture recorded the calls
// `fetchSettledTransaction` makes, which are known in advance; L2's hydration calls are NOT known in
// advance — the AVM discovers them — so the only list that can be right is the one produced by
// running the thing. `historical_state.ts` explains why that is the design and not a shortcut.
//
// AND THE HYDRATION READS GO THROUGH THE CLIENT, NOT THROUGH `fetch`. Both of them,
// `getPublicDataWitness` and `getNullifierMembershipWitness`, are already on L0's permitted fourteen
// and are members of the `MembershipWitnessSource` seam L0 declared for exactly this. So L2 needs no
// widening of the surface, no adapter, and no second wire path — and a recording made through the
// client is a recording upstream's own zod validates on every playback.

import { readFile, writeFile } from 'node:fs/promises';

import { BarretenbergSync } from '@aztec/bb.js';
import { jsonStringify } from '@aztec/foundation/json-rpc';
import { defaultFetch } from '@aztec/foundation/json-rpc/client';
import { Tx } from '@aztec/stdlib/tx';
import { TxHash } from '@aztec/stdlib/tx/tx-hash';

import {
  RUNG_BYTECODE_VALUE,
  RUNG_SOURCE_VALUE,
  buildSettledRecording,
  createReplayNodeClient,
  encodeRecordingInputs,
  encodeReplayInputs,
  fetchSettledTransaction,
  recordingIdFor,
  recordingPass,
  replaySettledTransaction,
  resolveContractArtifact,
} from '../src/index.ts';
import { CtWriter, ContractSourceMap, instantiateCtWriter, resolveTracingConfig,
  WRITER_PATH_B_NIM } from '../../ct-host/src/index.ts';
import { artifactCrypto, contractClassPublicLike, liveChainProviders }
  from './artifact_sources.mjs';
import { COMPONENTS_VERSION_FIELDS } from '../src/pinned_protocol_version.ts';
import { createNodeAvmHost } from './node_avm_host.ts';
import {
  SETTLED_FIXTURE_FORMAT,
  fixtureFetch,
  loadSettledFixture,
  recordingFetch,
} from './settled_fixture.ts';

const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : fallback;
};

const fixturePath = arg('fixture');
const capturePath = arg('capture');
// L5: WHERE THE SOURCE TEXT GOES, AND IT IS NOT THE REPORT.
//
// A resolved FeeJuice carries 32 source files; the token contract would carry 87. Putting them in
// the `--json` report would make a capture tool that pipes the report through a shell buffer carry
// megabytes of Noir per transaction, and `capture-chain.mjs` does exactly that. So the report
// carries the PATHS and the byte counts — enough to assert over — and the text goes to a file the
// consumer reads only if it is going to publish it.
const sourcesPath = arg('sources');
const modulePath = arg('module', process.env.AVM_WASM_PATH);
const ctOut = arg('ct');
const ctWriterPath = arg('ct-writer', process.env.CT_WRITER_WASM_PATH
  ?? 'ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm');
const json = argv.includes('--json');

// ---- THE BODY STORE: HOW A TRANSACTION BELOW THE FINALIZED TIP IS STILL REPLAYABLE -------------
//
// `getTxByHash` SERVES FROM THE MEMPOOL AND THE MEMPOOL DELETES AT THE FINALIZED TIP. That is
// `settled_transaction.ts`'s measured horizon, and it is the ONLY thing that stopped this driver
// from being pointed at a historical transaction: every other call a replay makes — `getTxEffect`,
// `getBlockData`, `getContract`, `getContractClass`, `getPublicDataWitness`,
// `getNullifierMembershipWitness` — reads the ARCHIVE and prunes never.
//
// Aztec publishes the bodies its node-internal `TxFileStore` holds, keyless over HTTPS, one
// content-addressed `.bin` per transaction hash. So the horizon is closed by a JOIN and not by an
// archive node: the node supplies everything about the block, the store supplies the body.
//
// NOTHING HERE IS PASTED. The base URL is read from `txCollectionFileStoreUrls` in
// `AztecProtocol/networks`' `network_config.json`; the path segment beneath it is
// `aztec-<l1ChainId>-<rollupVersion>-<rollupAddress>`, DERIVED FROM THE NODE'S OWN `getNodeInfo`.
// A location computed from the deployment the hash came from cannot silently drift onto a
// different deployment, which a pasted constant can and would not announce.
//
// AND THE PAYLOAD SELF-VERIFIES TWICE, because `Tx.toBuffer()` serialises `txHash` first:
//
//   1. the leading 32 bytes must BE the key that was requested; and
//   2. `tx.getTxHash()`, RECOMPUTED from the deserialised data, must be that key as well.
//
// (1) alone proves only that the object is labelled with the key. (2) proves the bytes under the
// label hash to it, which is what makes a single untrusted source usable at all. A response that
// fails either is REFUSED BY NAME rather than replayed — a body that is not this transaction's
// would produce a confident wrong trace, which is the whole class of defect this campaign exists
// to prevent.
//
// THE SHIM SITS UNDER `recordingFetch`, NOT OVER IT. The synthesised answer is therefore recorded
// into `--capture`'s fixture like any other, so a fixture captured this way plays back offline with
// no store and no network — and upstream's own zod validates the synthesised `Tx` on every
// playback, which is why it is serialised through `jsonStringify` rather than hand-built.
const bodyStoreArg = arg('body-store');
const bodyFile = arg('body-file');
const NETWORK_CONFIG_URL =
  'https://raw.githubusercontent.com/AztecProtocol/networks/main/network_config.json';

/** Every node call this run made, counted — see `--json`'s `nodeCalls`. */
const nodeCalls = { httpPosts: 0, rpcRequests: 0, byMethod: {} };
/** Every body-store GET this run made, and what each one was. */
const bodyStoreCalls = { gets: 0, verified: 0, outcomes: [] };

/** A `JsonRpcFetch` that counts what it forwards and forwards everything. */
function countingFetch(inner) {
  return async (host, body, extraHeaders, noRetry, config) => {
    const requests = Array.isArray(body) ? body : body === undefined ? [] : [body];
    nodeCalls.httpPosts += 1;
    nodeCalls.rpcRequests += requests.length;
    for (const r of requests) {
      if (typeof r?.method === 'string') {
        nodeCalls.byMethod[r.method] = (nodeCalls.byMethod[r.method] ?? 0) + 1;
      }
    }
    return inner(host, body, extraHeaders, noRetry, config);
  };
}

class BodyStoreRefused extends Error {
  constructor(outcome, reason) {
    super(`body store: ${outcome} — ${reason}`);
    this.name = 'BodyStoreRefused';
    this.kind = 'body-store-refused';
    this.outcome = outcome;
  }
}

/** `aztec-<l1ChainId>-<rollupVersion>-<rollupAddress>`, from the node's own answer. */
function storePathFor(nodeInfo) {
  return `aztec-${nodeInfo.l1ChainId}-${nodeInfo.rollupVersion}-`
    + `${nodeInfo.l1ContractAddresses.rollupAddress.toString()}`;
}

/** The store base for a network, out of the published config. Never a constant. */
async function storeBaseFor(network) {
  const res = await fetch(NETWORK_CONFIG_URL);
  if (!res.ok) {
    throw new BodyStoreRefused('unavailable',
      `${NETWORK_CONFIG_URL} answered HTTP ${res.status}, so the store location is not known. `
      + 'This tool will not invent one.');
  }
  const config = await res.json();
  const bases = config?.[network]?.txCollectionFileStoreUrls;
  if (!Array.isArray(bases) || bases.length === 0) {
    throw new BodyStoreRefused('unavailable',
      `the published network config declares no txCollectionFileStoreUrls for "${network}".`);
  }
  // The two-independent-sources rule is UNMET here and is recorded as unmet rather than relaxed.
  return { base: bases[0], sources: bases.length };
}

/**
 * Turn a body's bytes into the `getTxByHash` RESULT the client expects, verifying twice.
 *
 * Returns the JSON upstream's `Tx.schema` parses — produced by `jsonStringify(tx)` so that the
 * synthesised answer is byte-for-byte the shape the node would have sent.
 */
async function txResultFromBody(txHash, bytes) {
  const want = txHash.toLowerCase();
  if (bytes.length < 32) {
    throw new BodyStoreRefused('truncated',
      `${bytes.length} bytes cannot carry the 32-byte key a body serialises first.`);
  }
  const saw = `0x${Buffer.from(bytes.subarray(0, 32)).toString('hex')}`;
  if (saw !== want) {
    throw new BodyStoreRefused('mismatched',
      `the leading 32 bytes are ${saw}, not the requested ${want}. This is some other `
      + "transaction's body and replaying it would produce a confident wrong trace.");
  }
  await BarretenbergSync.initSingleton();
  const tx = Tx.fromBuffer(Buffer.from(bytes));
  const recomputed = (await tx.getTxHash()).toString().toLowerCase();
  if (recomputed !== want) {
    throw new BodyStoreRefused('hash-recomputation-failed',
      `the payload is LABELLED ${want} but its data hashes to ${recomputed}. The label is not `
      + 'the bytes, and only the recomputation can tell.');
  }
  return JSON.parse(jsonStringify(tx));
}

/**
 * A `JsonRpcFetch` that answers `getTxByHash` from the body store and forwards everything else.
 *
 * `fetchBody(hash)` returns `{status, bytes}`. A 404 is PASSED THROUGH to the node rather than
 * turned into an error, so the engine's own `SettledTransactionNotFound` still names `getTxByHash`
 * — "the store has a hole" and "this tool broke" are different sentences.
 */
function bodyStoreFetch(inner, fetchBody) {
  return async (host, body, extraHeaders, noRetry, config) => {
    const isBatch = Array.isArray(body);
    const requests = isBatch ? body : body === undefined ? [] : [body];
    const served = new Map();
    const forward = [];
    for (const req of requests) {
      const method = typeof req?.method === 'string' ? req.method : '';
      // THE PARAM IS NOT A STRING YET. `fetchImpl` is handed the request as JS OBJECTS — upstream's
      // client serialises with `jsonStringify` inside `defaultFetch`, AFTER this seam — so
      // `params[0]` here is a live `TxHash`, not the `0x…` the wire carries. Reading it as a string
      // silently matches nothing, which is a shim that looks installed and intercepts nothing.
      const raw = Array.isArray(req?.params) ? req.params[0] : undefined;
      const asText = typeof raw === 'string' ? raw : raw == null ? '' : String(raw);
      const key = /^0x[0-9a-f]{64}$/i.test(asText) ? asText.toLowerCase() : undefined;
      if (/getTxByHash$/i.test(method) && key !== undefined) {
        const { status, bytes } = await fetchBody(key);
        if (status === 200) {
          served.set(req.id, await txResultFromBody(key, bytes));
          continue;
        }
        if (status === 404) {
          console.error(`replay: body store has NO object for ${key} (404) — asking the node, `
            + 'which is expected to answer null below the finalized tip');
        } else {
          throw new BodyStoreRefused('unavailable',
            `the store answered HTTP ${status} for ${key}. Nothing is known about whether it `
            + 'holds this body; this is a fact about the run, not about the corpus.');
        }
      }
      forward.push(req);
    }
    if (served.size === 0) {
      return inner(host, body, extraHeaders, noRetry, config);
    }
    const collected = [];
    let headers = new Headers();
    if (forward.length > 0) {
      const answer = await inner(host, isBatch ? forward : forward[0], extraHeaders, noRetry,
        config);
      headers = answer.headers ?? headers;
      const rs = Array.isArray(answer.response)
        ? answer.response
        : answer.response === undefined ? [] : [answer.response];
      collected.push(...rs);
    }
    for (const [id, result] of served) {
      collected.push({ jsonrpc: '2.0', id, result });
    }
    const byId = new Map(collected.map(r => [r?.id, r]));
    const ordered = requests.map(r => byId.get(r?.id)).filter(r => r !== undefined);
    return { response: isBatch ? ordered : ordered[0], headers };
  };
}

if (!modulePath) {
  console.error('replay: --module <avm.wasm> (or AVM_WASM_PATH) is required. The shipped module is '
    + 'the one M9\'s observer patch is in; an unpatched build refuses the encoding by name.');
  process.exit(2);
}

let client;
let txHash;
let sink;
let url;

if (fixturePath) {
  const fixture = loadSettledFixture(JSON.parse(await readFile(fixturePath, 'utf8')), fixturePath);
  url = fixture.provenance.endpoint;
  txHash = fixture.provenance.txHash;
  client = createReplayNodeClient({ url, fetchImpl: fixtureFetch(fixture) });
} else {
  url = arg('url');
  if (!url) {
    console.error('replay: either --fixture <path> or --url <rpc> is required');
    process.exit(2);
  }
  sink = { calls: [], batchHeaders: {}, headerNames: COMPONENTS_VERSION_FIELDS.map(f => `x-aztec-${f.toLowerCase()}`) };
  // THE STORE LOCATION IS RESOLVED LAZILY, AND THAT IS THE POINT: it is derived from
  // `getNodeInfo`, which means it needs the client that is being built here. Resolving it on first
  // use is what makes the derivation possible at all without a second, unguarded wire path — the
  // `getNodeInfo` call goes through this same counted client and lands in the capture like any
  // other.
  const network = url.includes('testnet') ? 'testnet' : 'mainnet';
  let storeLocation = null;
  const fetchBody = async (hash) => {
    if (bodyFile) {
      const bytes = await readFile(bodyFile);
      bodyStoreCalls.outcomes.push({ hash, source: bodyFile, outcome: 'local-file',
        bytes: bytes.length });
      return { status: 200, bytes };
    }
    if (storeLocation === null) {
      const resolved = bodyStoreArg === 'auto'
        ? await storeBaseFor(network)
        : { base: bodyStoreArg, sources: 1 };
      storeLocation = { ...resolved, path: storePathFor(await client.getNodeInfo()) };
      console.error(`replay: body store ${storeLocation.base}/${storeLocation.path}/txs/ `
        + `(${storeLocation.sources} published source(s)`
        + `${storeLocation.sources < 2 ? ', so the two-source rule is UNMET and recorded as unmet' : ''})`);
    }
    const target = `${storeLocation.base}/${storeLocation.path}/txs/${hash}.bin`;
    bodyStoreCalls.gets += 1;
    const res = await fetch(target);
    const bytes = res.ok ? Buffer.from(await res.arrayBuffer()) : Buffer.alloc(0);
    bodyStoreCalls.outcomes.push({ hash, url: target, status: res.status, bytes: bytes.length });
    if (res.status === 200) {
      bodyStoreCalls.verified += 1;
      console.error(`replay: body store GET ${target} -> 200, ${bytes.length} bytes`);
    }
    return { status: res.status, bytes };
  };
  const counted = countingFetch(defaultFetch);
  client = createReplayNodeClient({
    url,
    fetchImpl: recordingFetch(
      bodyStoreArg || bodyFile ? bodyStoreFetch(counted, fetchBody) : counted, sink),
  });
  txHash = arg('tx');
  if (!txHash) {
    // Walk back from the tip for a transaction whose BODY the node still serves. The horizon is a
    // finality lag, so `getBlockNumber('finalized')` bounds the search rather than a guessed depth.
    const tip = await client.getBlockNumber();
    const finalized = await client.getBlockNumber('finalized');
    console.error(`replay: tip ${tip}, finalized ${finalized} — ${tip - finalized} replayable block(s)`);
    search: for (let n = tip; n > finalized; n--) {
      const block = await client.getBlock(n, { includeTransactions: true });
      for (const effect of block?.body?.txEffects ?? []) {
        // FIRST IN ITS BLOCK ONLY. `IntraBlockPredecessorsUnavailable` is the refusal, and finding
        // out here rather than after a fetch keeps the recording free of a transaction it cannot use.
        if (effect !== block.body.txEffects[0]) continue;
        try { await client.fetchSettledTx(effect.txHash); } catch { continue; }
        txHash = effect.txHash.toString();
        break search;
      }
    }
    if (!txHash) {
      console.error('replay: no first-in-block transaction with a retained body above the finalized tip');
      process.exit(1);
    }
  }
}

console.error(`replay: ${txHash} via ${url}`);

const settled = await fetchSettledTransaction(client, TxHash.fromString(txHash), {
  pinToSettlingBlock: true,
});
const host = await createNodeAvmHost(modulePath);

const outcome = await replaySettledTransaction(host, client, settled, encodeReplayInputs, {
  onRound: (r) => console.error(
    `replay: round ${r.round} — ${r.queries} quer(y|ies) reported, ${r.added} leaf/leaves seeded, `
    + `${r.skipped.length} skipped`),
});

// ---- L3: THE RECORDING --------------------------------------------------------------------------
// Written BEFORE the wrong-block control pass, deliberately: the control re-runs the loop and would
// leave `outcome` describing an execution nobody wants a container of.
// ---- L5: RESOLVE THE ARTIFACTS *BEFORE* THE WRITER EXISTS -----------------------------------
//
// THE ORDER IS FORCED AND IT IS NOT A STYLE CHOICE. A session's mapping rung and its column
// awareness are fixed when the `CtWriter` is CONSTRUCTED — `resolveTracingConfig` throws
// `ColumnAwarenessUnavailable` for `columns: true` below rung 1 — so whether this transaction can
// be recorded at source level has to be known before the constructor runs. Resolution reaches a
// registry and an explorer; the writer reaches a wasm module; doing them in the other order would
// mean either opening at rung 3 and discovering source we cannot use, or opening at rung 1 on
// speculation and refusing the container at close.
const artifactResolutions = [];
if (ctOut) {
  const providers = liveChainProviders({
    // OMITTED FOR A FIXTURE PLAYBACK, ON PURPOSE. `--fixture` is the mode the offline checks run
    // in, and reaching an explorer from it would make `just verify-l3` depend on somebody else's
    // uptime — the rule `verify-l1`'s header states. With no chain named the resolver asks the
    // installed package and nothing else, which is enough for a protocol contract and honestly
    // reports "no artifact proved" for a third-party one.
    chain: fixturePath ? undefined : (url.includes('testnet') ? 'aztec-testnet' : 'aztec-mainnet'),
  });
  for (const contract of settled.contracts) {
    if (!contract.resolved || contract.contractClass === undefined) continue;
    const resolution = await resolveContractArtifact(
      contract.address,
      contractClassPublicLike(contract.contractClass),
      providers,
      artifactCrypto,
    );
    artifactResolutions.push(resolution);
    console.error(`replay: artifact ${contract.address.slice(0, 14)}… class `
      + `${contract.contractClassId.slice(0, 14)}… -> `
      + (resolution.resolved
        ? `PROVED by ${resolution.artifact.origin} (${resolution.corroboration}, `
          + `${resolution.artifact.files.size} source file(s))`
        : `NOT PROVED — ${resolution.candidatesConsidered} candidate(s), `
          + `${resolution.rejected.length} rejected`));
  }
}
const anythingResolved = artifactResolutions.some(r => r.resolved);

let recording = null;
if (ctOut) {
  const writerBytes = await readFile(ctWriterPath);
  // THE SESSION RUNG IS NOW A MEASUREMENT AND NOT A CONSTANT.
  //
  // It was `RUNG_BYTECODE_VALUE` unconditionally, with a comment explaining that an Aztec node
  // serves no debug symbols and no file map — which is still true and is still why an unresolved
  // transaction opens here at rung 3 with `columns: false`. What changed is that when an artifact
  // has been PROVED off-chain there is a real `(path, line, column)` for a step to carry, and
  // `SOURCE-MAPPING.md` §3.1's rule then applies: columns are recordable when the recording
  // resolves to rung 1.
  //
  // THE SESSION'S RUNG AND A CONTRACT'S RUNG ARE DIFFERENT QUESTIONS (M29's distinction, kept). The
  // session's says what SHAPE the positions this recording writes have; each contract's says how
  // much of ITS execution was covered, and `buildSettledRecording` measures that per contract over
  // the executed stream. A transaction with one resolved contract opens at rung 1 and can still
  // declare rung 3 for a second contract that resolved nothing.
  const writer = new CtWriter(
    await instantiateCtWriter(writerBytes),
    resolveTracingConfig({
      program: 'aztec-live-chain-replay',
      recordingId: recordingIdFor(settled.txHash,
        settled.blockData.header.globalVariables.timestamp),
      sourcePath: `/aztec/${settled.txHash}.avm`,
      workdir: '/aztec',
      mappingRung: anythingResolved ? RUNG_SOURCE_VALUE : RUNG_BYTECODE_VALUE,
      // COLUMNS FOLLOW THE RUNG, AND THE ARTEFACT REFUSED THEM BEFORE THIS COMMENT EXISTED.
      // L3's first draft copied `columns: true` from the browser path while opening at rung 3, and
      // `resolveTracingConfig` threw `ColumnAwarenessUnavailable`: "enabling column mode would
      // advertise breakpoint-sharp columns over positions that are program counters." That guard is
      // exactly right and it still runs — what L5 changed is that when an artifact is proved the
      // positions are no longer program counters, so the guard is satisfied rather than bypassed.
      columns: anythingResolved,
    }, WRITER_PATH_B_NIM),
    { batchRecords: 64 },
  );
  // THE STEP PASS. The hydration pass ran with `collectHints` on and therefore produced NO step
  // stream — see RECORDING_PASS_REASON. This runs the same seed again with the flags the other way
  // round, and REFUSES if the two passes do not describe the same execution.
  const pass = await recordingPass(host, settled, outcome, encodeRecordingInputs);
  console.error(`replay: step pass — ${pass.steps?.length ?? 'NULL'} step(s), revertCode `
    + `${pass.revertCode}, ${pass.verdict.matched}/${pass.verdict.comparisons.length} matched, `
    + 'and it agrees with the hydration pass');
  // THE MAPS ARE BUILT HERE, AFTER THE WRITER, BECAUSE `internPath` NEEDS AN OPEN SESSION. The
  // proof was done above with no writer at all, which is the split that matters: what is proved is
  // a fact about the chain, and what is interned is a fact about this container.
  const sources = artifactResolutions.filter(r => r.resolved).map(r => ({
    address: r.address,
    map: new ContractSourceMap(
      r.artifact.debugInfo,
      r.artifact.bytecode.length,
      r.artifact.files,
      (p, ll) => writer.internPath(p, ll),
    ),
    proof: r.reason,
    corroboration: r.corroboration,
    origin: r.artifact.origin,
  }));
  recording = buildSettledRecording(writer, settled, { ...outcome, steps: pass.steps }, pass.steps,
    sources);
  await writeFile(ctOut, recording.container);
  console.error(`replay: wrote ${ctOut} — ${recording.bytes} bytes, ${recording.events} event(s), `
    + `${recording.steps} step(s), ${recording.callsOpened} frame(s), `
    + `${recording.logEvents} log event(s), rung ${recording.declaredRung}, `
    + `sourceLevel ${recording.sourceLevel}, positioned ${recording.stepsPositioned}/`
    + `${recording.stepsPositioned + recording.stepsUnpositioned}`);
  for (const c of recording.contractRungs) {
    console.error(`replay:   ${c.address.slice(0, 14)}… rung ${c.rung} `
      + `(${c.positioned}/${c.steps} positioned${c.resolved ? '' : ', no artifact proved'})`);
  }

  // ---- L5: THE SOURCE BUNDLE, KEYED BY CONTRACT CLASS ID ---------------------------------------
  //
  // **THE KEY IS THE CLASS ID AND NOT THE ADDRESS**, because the class id IS the chain's code
  // hash: two instances of one class run the same bytecode and must not each publish a copy of the
  // same source, and one address whose class was updated must not have two versions of its source
  // collapsed onto one key. `blocktracer`'s `CodeEdge` is documented as "versioned edge keyed by
  // code hash, never a column" and this is the value that makes that true here.
  //
  // Written only for contracts whose artifact was PROVED. A bundle for an unproved contract would
  // be source text the chain has not committed to, published beside a trace, which is the whole
  // failure this milestone is built around.
  if (sourcesPath) {
    const bundles = artifactResolutions.filter(r => r.resolved).map(r => ({
      address: r.address,
      codeHash: r.contractClassId,
      artifactHash: r.artifact.artifactHash,
      origin: r.artifact.origin,
      shape: r.artifact.shape,
      corroboration: r.corroboration,
      agreeingDistributors: r.agreeingDistributors,
      debugDigest: r.artifact.debugDigest,
      // `path -> content`, the shape `writeSourceBundle`'s `sources` object wants. The paths are
      // the artifact's own — absolute build paths out of upstream's CI, e.g.
      // `/home/aztec-dev/aztec-packages/noir-projects/…/main.nr` — and they are NOT rewritten,
      // because they are the exact strings this container interned and a bundle whose keys do not
      // match the interned paths is a bundle the viewer cannot use.
      files: Object.fromEntries([...r.artifact.files.values()].map(f => [f.path, f.source])),
    }));
    await writeFile(sourcesPath, `${JSON.stringify({
      txHash: settled.txHash,
      sourceLevel: recording.sourceLevel,
      bundles,
    }, null, 2)}\n`);
    console.error(`replay: wrote ${sourcesPath} — ${bundles.length} source bundle(s), `
      + `${bundles.reduce((n, b) => n + Object.keys(b.files).length, 0)} file(s)`);
  }
}

// ---- THE CONTROL'S DATA, CAPTURED AS A REAL CHAIN ANSWER ----------------------------------------
// `e2e_replay_matches_published_effects`'s control replays against the WRONG block's state — the
// SETTLING block instead of its parent — so every read returns the value the transaction itself
// wrote and the comparison must fail. That control has to run OFFLINE like everything else, so its
// answers are captured here, from the live node, in the same run.
//
// IT IS A SECOND PASS AND NOT A SECOND FUNCTION. The loop is re-run with
// `preStateBlockForControls: 'settling-block'`, so what gets recorded is exactly the set of calls
// the control will make — the same discovery, at the other block. Listing the slots by hand would
// be a guess about what the control asks for, which is the mistake `historical_state.ts` exists to
// stop being made about the subject.
//
// L1's precedent: its fabricated probes are asked OF THE LIVE NODE so that its own answers are on
// record, rather than synthesised. Same here, with nothing fabricated at all — every one of these
// is a real witness at a real block.
if (capturePath) {
  console.error('replay: capturing the wrong-block control\'s answers (pre-state at the SETTLING '
    + 'block, which is what the control replays against)');
  try {
    await replaySettledTransaction(host, client, settled, encodeReplayInputs, {
      preStateBlockForControls: 'settling-block',
      onRound: (r) => console.error(
        `replay: [control] round ${r.round} — ${r.queries} reported, ${r.added} seeded`),
    });
    console.error('replay: [control] the wrong-block run CONVERGED — its calls are recorded');
  } catch (err) {
    // A control that refuses is still a control, and its calls are still recorded. What must not
    // happen is the capture aborting: the subject's own recording is already complete by this
    // point, and losing it because the control threw would be the tail wagging the dog.
    console.error(`replay: [control] the wrong-block run ended with ${err?.name ?? 'an error'} — `
      + 'recorded anyway, which is what the control is for');
  }
}

// ---- the report -------------------------------------------------------------------------------
const report = {
  txHash: settled.txHash,
  l2BlockNumber: settled.l2BlockNumber,
  preStateReadAt: settled.l2BlockNumber - 1,
  txIndexInBlock: settled.txIndexInBlock,
  contractReferenceBlock: settled.contracts[0]?.resolvedAsOf ?? null,
  rounds: outcome.rounds.length,
  seedSize: outcome.seedSize,
  instructionsExecuted: outcome.instructionsExecuted,
  published: { revertCode: settled.revertCode },
  replayed: { revertCode: outcome.revertCode },
  verdict: {
    reproduced: outcome.verdict.reproduced,
    matched: outcome.verdict.matched,
    mismatched: outcome.verdict.mismatched,
  },
  mismatches: outcome.verdict.comparisons.filter(c => !c.matches),
  steps: outcome.steps?.length ?? null,
  recording: recording === null ? null : {
    bytes: recording.bytes, events: recording.events, steps: recording.steps,
    callsOpened: recording.callsOpened, logEvents: recording.logEvents,
    declaredRung: recording.declaredRung, distinctOpcodes: recording.distinctOpcodes,
    contexts: recording.contexts, stepsPositioned: recording.stepsPositioned,
    stepsUnpositioned: recording.stepsUnpositioned,
    // L5. `sourceLevel` is the field `blocktracer`'s manifest publishes, and it travels with the
    // per-contract detail so a consumer never has to infer the second from the first.
    sourceLevel: recording.sourceLevel,
    contractRungs: recording.contractRungs,
  },
  // L5: THE RESOLUTION ITSELF, INCLUDING EVERY REJECTION. A capture that recorded only successes
  // could not tell "we did not look" from "we looked and nothing matched", and the second is the
  // sentence a transaction page has to be able to say.
  artifacts: artifactResolutions.map(r => (r.resolved
    ? {
      address: r.address, contractClassId: r.contractClassId, resolved: true,
      origin: r.artifact.origin, shape: r.artifact.shape,
      artifactHash: r.artifact.artifactHash, debugDigest: r.artifact.debugDigest,
      sourceFiles: r.artifact.files.size, corroboration: r.corroboration,
      agreeingDistributors: r.agreeingDistributors,
      sources: [...r.artifact.files.values()].map(f => ({ path: f.path, bytes: f.source.length })),
      reason: r.reason,
      rejected: r.rejected.map(x => ({ origin: x.origin, fault: x.fault })),
    }
    : {
      address: r.address, contractClassId: r.contractClassId, resolved: false,
      candidatesConsidered: r.candidatesConsidered, reason: r.reason,
      rejected: r.rejected.map(x => ({ origin: x.origin, fault: x.fault })),
    })),
  roots: outcome.roots.declarations,
  rootsAnyAgree: outcome.roots.anyAgrees,
  skipped: outcome.rounds.flatMap(r => r.skipped.map(s => ({ value: s.value, reason: s.reason }))),
  // WHAT THIS ONE TRANSACTION COST, which is the number that decides whether a corpus-wide
  // re-recording is hours or months. `rpcRequests` is the honest count — upstream BATCHES, so
  // `httpPosts` is smaller and is not what a rate limiter counts.
  nodeCalls: fixturePath ? null : nodeCalls,
  bodyStore: bodyStoreArg || bodyFile ? bodyStoreCalls : null,
};

if (json) {
  console.log(JSON.stringify(report, null, 2));
} else {
  console.log(`\ntransaction ${report.txHash}`);
  console.log(`block ${report.l2BlockNumber} (index ${report.txIndexInBlock}), `
    + `pre-state read at ${report.preStateReadAt}, contracts resolved as of ${report.contractReferenceBlock}`);
  console.log(`hydration: ${report.rounds} round(s), `
    + `${report.seedSize.nullifiers} nullifier(s) + ${report.seedSize.publicData} public-data leaf/leaves seeded`);
  console.log(`executed:  ${report.instructionsExecuted} instruction(s)`);
  console.log(`revertCode: published ${report.published.revertCode}, replayed ${report.replayed.revertCode}`);
  console.log(`published effects reproduced: ${report.verdict.reproduced ? 'YES' : 'NO'} `
    + `(${report.verdict.matched} matched, ${report.verdict.mismatched} mismatched)`);
  for (const m of report.mismatches) {
    console.log(`   MISMATCH ${m.field}: published ${m.published} replayed ${m.replayed}`);
  }
  if (report.nodeCalls) {
    console.log(`node calls: ${report.nodeCalls.rpcRequests} JSON-RPC request(s) in `
      + `${report.nodeCalls.httpPosts} HTTP POST(s)`
      + (report.bodyStore ? `, plus ${report.bodyStore.gets} body-store GET(s)` : ''));
    for (const [m, n] of Object.entries(report.nodeCalls.byMethod).sort((a, b) => b[1] - a[1])) {
      console.log(`   ${String(n).padStart(4)}  ${m}`);
    }
  }
  console.log('\ntree roots — EXPECTED TO DIFFER, and the reason travels with the outcome:');
  for (const d of report.roots) {
    console.log(`   ${d.tree.padEnd(20)} resident ${d.resident.slice(0, 18)}…  chain ${d.chain.slice(0, 18)}…  ${d.agrees ? 'AGREES' : 'differs'}`);
  }
}

if (capturePath) {
  const nodeInfo = await client.getNodeInfo();
  const fixture = {
    format: SETTLED_FIXTURE_FORMAT,
    provenance: {
      endpoint: url,
      chain: url.includes('testnet') ? 'aztec-testnet' : 'aztec-mainnet',
      l1ChainId: nodeInfo.l1ChainId,
      rollupVersion: nodeInfo.rollupVersion,
      l1RollupAddress: nodeInfo.l1ContractAddresses.rollupAddress.toString(),
      nodeVersion: nodeInfo.nodeVersion,
      capturedAt: new Date().toISOString(),
      capturedBy: 'replay/tools/replay_settled_transaction.mjs --capture',
      txHash: settled.txHash,
      l2BlockNumber: settled.l2BlockNumber,
      txIndexInBlock: settled.txIndexInBlock,
      chainTipAtCapture: await client.getBlockNumber(),
      contractReferenceBlock: settled.contracts[0]?.resolvedAsOf ?? 'latest',
      contractReferenceBlockRequested: 'settling-block',
      replayReport: report,
      nodeReported: {
        revertCode: settled.revertCode,
        l2BlockHash: settled.l2BlockHash,
        transactionFee: settled.txEffect.data.transactionFee.toString(),
        enqueuedPublicCalls: settled.publicHalf.enqueuedCalls,
        hasTeardown: settled.publicHalf.hasTeardown,
        publicCallTargets: settled.contracts.map(c => c.address),
        contracts: settled.contracts.map(c => ({
          address: c.address, contractClassId: c.contractClassId,
          originalContractClassId: c.originalContractClassId,
          packedBytecodeBytes: c.packedBytecodeBytes,
        })),
        publishedEffects: {
          noteHashes: settled.txEffect.data.noteHashes.length,
          nullifiers: settled.txEffect.data.nullifiers.length,
          privateLogs: settled.txEffect.data.privateLogs.length,
          publicLogs: settled.txEffect.data.publicLogs.length,
          publicDataWrites: settled.txEffect.data.publicDataWrites.length,
          contractClassLogs: settled.txEffect.data.contractClassLogs.length,
          l2ToL1Msgs: settled.txEffect.data.l2ToL1Msgs.length,
        },
        globalVariables: {
          blockNumber: settled.blockData.header.globalVariables.blockNumber,
          timestamp: String(settled.blockData.header.globalVariables.timestamp),
          chainId: settled.blockData.header.globalVariables.chainId.toString(),
          version: settled.blockData.header.globalVariables.version.toString(),
          feePerDaGas: String(settled.blockData.header.globalVariables.gasFees.feePerDaGas),
          feePerL2Gas: String(settled.blockData.header.globalVariables.gasFees.feePerL2Gas),
        },
        stateReference: {
          noteHashTreeRoot: settled.blockData.header.state.partial.noteHashTree.root.toString(),
          nullifierTreeRoot: settled.blockData.header.state.partial.nullifierTree.root.toString(),
          publicDataTreeRoot: settled.blockData.header.state.partial.publicDataTree.root.toString(),
          l1ToL2MessageTreeRoot: settled.blockData.header.state.l1ToL2MessageTree.root.toString(),
          archiveRoot: settled.blockData.archive.root.toString(),
        },
      },
      fabricatedProbes: {
        note: 'This L2 recording contains NO fabricated values. Every call in it is a call the '
          + 'replay itself made against a live node. L1\'s fixtures carry deliberate probes for '
          + 'their refusal controls; this one does not, and says so rather than leaving the field out.',
      },
      versionHeaders: {
        onBatchPost: sink.batchHeaders,
        onSingleObjectPost: {},
        note: 'onBatchPost is what upstream\'s client SAW. This capture does not take the un-batched '
          + 'reconstruction L1\'s does — see pins.json live_chain: the proxy strips the headers on '
          + 'the batch POST upstream always sends, which is measured there and not re-measured here.',
      },
    },
    calls: sink.calls,
  };
  await writeFile(capturePath, `${JSON.stringify(fixture, null, 2)}\n`);
  console.error(`replay: wrote ${capturePath} — ${sink.calls.length} recorded call(s)`);
}

process.exit(outcome.verdict.reproduced ? 0 : 1);
