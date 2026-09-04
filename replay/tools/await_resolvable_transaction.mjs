#!/usr/bin/env node
// await_resolvable_transaction.mjs — WAIT FOR A SETTLED TRANSACTION WHOSE CONTRACTS' ARTIFACTS CAN
// BE PROVED OFF-CHAIN, THEN CAPTURE ITS FIXTURE AND RECORD IT AT THE RUNG IT EARNS.
//
// ────────────────────────────────────────────────────────────────────────────────────────────────
// WHY THIS EXISTS AT ALL, AND IT IS A MEASUREMENT RATHER THAN A CONVENIENCE.
//
// L5's demonstration wanted a re-recording of the frozen container `0x12525d6d…` — the one whose
// FeeJuice class is the only class any of this campaign's captures resolves. **It cannot be
// re-recorded.** `getTxByHash` serves only from the active tx pool and the pool deletes at the
// FINALIZED tip; that transaction settled in testnet block 63670 and `getTxByHash` answers `null`
// for it, measured 2026-09-01 at tip 65171. A replay needs the `Tx` — it is what `AvmTxHint.fromTx`
// consumes — so the subject of that container no longer exists to be replayed.
//
// And a subject cannot simply be picked out of the current window either: over 2026-09-01's
// replayable window every settled transaction on testnet called ONE third-party token contract
// (class `0x2b674941…`), whose artifact is published nowhere and verified on no explorer. So a
// source-level chain recording needs a transaction that (a) is inside the ~1-hour replayable window
// and (b) touches a class somebody publishes — and the only way to have one is to wait for one.
//
// **THE WAITING IS THE HONEST OPTION AND THE ALTERNATIVES ARE NAMED SO THEY ARE NOT RE-PROPOSED:**
//
//   * *Re-record the frozen container from its own step records.* That is fabrication: the step
//     stream would come from a container rather than from the AVM, which is the "fabricating path"
//     `recording.ts` refuses by construction.
//   * *Submit our own transaction.* It writes to a chain this repository only reads, and it makes
//     the demonstration a demonstration of our wallet.
//   * *Point the demonstration at the browser demo's token transfer.* Already rung 1, and it proves
//     nothing about CHAIN-FETCHED artifacts, which is the entire subject.
//   * *Widen the scan below the finalized tip.* Those transactions are visible and unreplayable —
//     L1's measured horizon — so the scan would find subjects it cannot use.
//
// USAGE
//   node replay/tools/await_resolvable_transaction.mjs --url <rpc> --out <dir> [--interval 60]
//        [--deadline-minutes 240] [--module <avm.wasm>] [--ct-writer <p>]
//
// It prints one line per poll — the window, the transactions seen, and per contract whether an
// artifact was proved — so a run that finds nothing is a RECORD of the chain over that period
// rather than silence. A poll that sees zero transactions says so; a poll that sees transactions
// and proves nothing names the classes it could not prove.

import { spawn } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';

import { defaultFetch } from '@aztec/foundation/json-rpc/client';
import { TxHash } from '@aztec/stdlib/tx/tx-hash';

import { createReplayNodeClient, fetchSettledTransaction, resolveContractArtifact }
  from '../src/index.ts';
import { artifactCrypto, contractClassPublicLike, liveChainProviders }
  from './artifact_sources.mjs';

const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : fallback;
};

const url = arg('url', 'https://aztec-testnet.drpc.org');
const outDir = resolve(arg('out', 'scratchpad/l5-live'));
const intervalSeconds = Number(arg('interval', 60));
const deadlineMinutes = Number(arg('deadline-minutes', 240));
const modulePath = arg('module', process.env.AVM_WASM_PATH);
const ctWriterPath = arg('ct-writer', process.env.CT_WRITER_WASM_PATH);
const chain = url.includes('testnet') ? 'aztec-testnet' : 'aztec-mainnet';

if (!modulePath || !ctWriterPath) {
  console.error('await: --module <avm.wasm> and --ct-writer <aztec_ct_writer.wasm> are required '
    + '(or $AVM_WASM_PATH / $CT_WRITER_WASM_PATH). This tool records when it finds a subject, and '
    + 'discovering the module is missing AFTER a one-hour wait would throw the subject away.');
  process.exit(2);
}

await mkdir(outDir, { recursive: true });
const client = createReplayNodeClient({ url, fetchImpl: defaultFetch });
const providers = liveChainProviders({ chain });

const startedAt = Date.now();
const seen = new Set();
const log = [];
const note = (line) => {
  const stamped = `${new Date().toISOString()} ${line}`;
  console.error(`await: ${stamped}`);
  log.push(stamped);
};

note(`watching ${url} for a settled transaction whose contract artifacts can be PROVED off-chain; `
  + `polling every ${intervalSeconds}s, giving up after ${deadlineMinutes} minute(s)`);

let found = null;
while (found === null && Date.now() - startedAt < deadlineMinutes * 60_000) {
  let tip;
  let finalized;
  try {
    tip = await client.getBlockNumber();
    finalized = await client.getBlockNumber('finalized');
  } catch (err) {
    // A NODE THAT DID NOT ANSWER IS RECORDED AND SLEPT ON, never treated as an empty window: a
    // window with no transactions and a node that refused to say are different facts, and only the
    // first one is about the chain.
    note(`poll FAILED to read the window: ${err?.name ?? 'error'} ${String(err?.message).slice(0, 120)}`);
    await new Promise(r => setTimeout(r, intervalSeconds * 1000));
    continue;
  }

  let considered = 0;
  const unproved = [];
  for (let n = tip; n > finalized && found === null; n--) {
    let block;
    try { block = await client.getBlock(n, { includeTransactions: true }); } catch { continue; }
    const effects = block?.body?.txEffects ?? [];
    // FIRST IN BLOCK ONLY — `IntraBlockPredecessorsUnavailable` is L2's refusal and a subject that
    // cannot be replayed is not a subject.
    if (effects.length === 0) continue;
    const hash = effects[0].txHash.toString();
    if (seen.has(hash)) continue;
    seen.add(hash);
    considered += 1;
    let settled;
    try {
      settled = await fetchSettledTransaction(client, TxHash.fromString(hash),
        { pinToSettlingBlock: true });
    } catch (err) {
      note(`  block ${n} ${hash.slice(0, 14)}… refused: ${err?.name ?? 'error'}`);
      continue;
    }
    const proved = [];
    for (const contract of settled.contracts) {
      if (!contract.resolved || contract.contractClass === undefined) continue;
      const resolution = await resolveContractArtifact(contract.address,
        contractClassPublicLike(contract.contractClass), providers, artifactCrypto);
      if (resolution.resolved) proved.push(resolution);
      else unproved.push(`${contract.contractClassId.slice(0, 14)}…`);
    }
    // ONE PROVED CONTRACT IS THE BAR, and the ratio is recorded rather than required.
    //
    // This read `proved.length === all`, justified by `SettledRecording.sourceLevel`
    // being a conjunction. It is — but `sourceLevel` is only ONE of the three ways past
    // the actual publish bar, which is `ingest.nim`'s
    //
    //     measuredSourceLevel or hasPostHocPositions or
    //     (recording.stepsPositioned > 0 and a positions file)
    //
    // The transaction this repository already publishes settles it: testnet
    // `0x20ed5b91…` has `sourceLevel: false`, sits at rung 2 with 86 of 108 steps
    // positioned, and ships a source bundle through the third disjunct. Under the old
    // conjunction a subject exactly like it would have been vetoed by this file for
    // failing a condition its own published sibling does not meet.
    //
    // AND A VETO HERE IS PERMANENT. `getTxByHash` serves only the active pool, which
    // deletes at the finalized tip, so a transaction passed over is replayable for about
    // an hour and then never again — the same one-way door the commit above this one
    // exists to close. A rejection is not "wait for a better subject next poll"; it is
    // that subject destroyed. The asymmetry is total: accepting a half-proved container
    // costs a weaker demonstration, rejecting one costs the container.
    //
    // The repository already treats this as a valid container elsewhere —
    // `e2e_resolved_contract_records_at_source_level.sh`'s `mixed` arm is two contracts,
    // one proved and one not, asserted to produce rungs 1 AND 3 in ONE container without
    // throwing. Vetoing here what that arm asserts is publishable was the contradiction.
    //
    // `all` IS CARRIED ON THE SUBJECT, not merely logged per candidate, so the rung stays
    // legible: a reader of the run has to be able to see "2 contract(s), 1 proved" against
    // the transaction that was chosen, and not only against the ones that were passed over.
    const all = settled.contracts.filter(c => c.resolved).length;
    note(`  block ${n} ${hash.slice(0, 14)}… ${all} contract(s), ${proved.length} proved`);
    if (proved.length > 0) {
      found = { hash, blockNumber: n, proved, all };
    }
  }
  if (found === null) {
    note(`poll: window ${finalized + 1}..${tip} (${tip - finalized} block(s)), ${considered} new `
      + `first-in-block transaction(s), 0 with a provable artifact`
      + (unproved.length === 0 ? '' : `; unprovable classes seen: ${[...new Set(unproved)].join(', ')}`));
    await new Promise(r => setTimeout(r, intervalSeconds * 1000));
  }
}

if (found === null) {
  note(`gave up after ${deadlineMinutes} minute(s) with no provable subject. THAT IS A FACT ABOUT `
    + 'THE CHAIN OVER THAT PERIOD and it is in await-log.txt with a timestamp per poll.');
} else {
  // THE RATIO IS ON THE VERDICT LINE. `proved.length` alone reads as "this subject was
  // fully proved" whatever it was; printed against `all` it says which rung the container
  // is going to be able to reach, which is the thing a reader of this run needs and the
  // thing the removed `=== all` conjunction used to imply for free.
  note(`FOUND ${found.hash} in block ${found.blockNumber}, `
    + `${found.all} contract(s), ${found.proved.length} proved: `
    + found.proved.map(p => `${p.address.slice(0, 12)}… <- ${p.artifact.origin} (${p.corroboration})`).join('; '));
}

// WRITTEN AFTER THE VERDICT AND NOT BEFORE IT. This stood above the two notes, so the
// line saying which transaction was chosen — or that none was — reached stderr and never
// the file, and `await-log.txt` ended at the last poll. The log is the artefact the run
// is read from afterwards; a verdict it does not carry is a verdict nobody can check.
await writeFile(join(outDir, 'await-log.txt'), `${log.join('\n')}\n`);

if (found === null) process.exit(3);

// Hand off to the driver rather than re-implementing it. The recording this produces has to be the
// one the shipped path produces or the demonstration is of this file instead of of that one.
const child = spawn(process.execPath, [
  '--experimental-strip-types',
  new URL('./replay_settled_transaction.mjs', import.meta.url).pathname,
  '--url', url,
  '--tx', found.hash,
  '--module', modulePath,
  '--ct-writer', ctWriterPath,
  '--ct', join(outDir, `${found.hash}.ct`),
  '--capture', join(outDir, `${found.hash}.fixture.json`),
  // THE SOURCE TEXT, WRITTEN OUT AT RECORD TIME. A subject found here is inside the ~1-hour
  // replayable window and the run that finds it is the only run that will ever have it live; a
  // publisher that wanted the text later would be asking a pool that has already deleted the body.
  // `replay_settled_transaction.mjs`'s `--sources` header says why it is a file and not the report.
  '--sources', join(outDir, `${found.hash}.sources.json`),
  // THE OTHER HALF OF THE REPLAY'S INPUTS. The JSON-RPC fixture holds the transaction body — the
  // part the pool deletes — and this holds the artifact candidates, so a re-record a month from now
  // resolves what THIS run resolved rather than whatever is installed then. Without it a fixture
  // can reproduce the execution and still not reproduce the container.
  '--artifacts', join(outDir, `${found.hash}.artifacts.json`),
  '--json',
], { stdio: ['ignore', 'pipe', 'inherit'] });
let stdout = '';
child.stdout.on('data', (d) => { stdout += d; process.stderr.write(d); });
const code = await new Promise(r => child.on('close', r));
await writeFile(join(outDir, `${found.hash}.report.json`), stdout);
note(`driver exited ${code}; report written`);
process.exit(code === 0 ? 0 : 4);
