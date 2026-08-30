#!/usr/bin/env node
// replay_window.mjs — L4's driver: every replayable transaction, with a per-transaction outcome
// table.
//
// THE RANGE IS THE REPLAYABLE WINDOW AND IS NOT A PARAMETER. `range.ts` explains why: the window's
// two ends are `getBlockNumber('finalized') + 1` and `getBlockNumber()`, both already on L0's
// permitted fourteen, and anything older is unreplayable by construction. A `--from` that reached
// below it would only fill the table with one row repeated.
//
// THIS RECIPE NEEDS A LIVE CHAIN and is the only L4 one that does. The window is a property of the
// chain at the moment it is read; a fixture of it would be a fixture of a moment.
//
// Usage:
//   node tools/replay_window.mjs --url <rpc> --module <avm.wasm> [--max N] [--json]

import {
  createReplayNodeClient,
  encodeReplayInputs,
  replayReplayableWindow,
} from '../src/index.ts';
import { createNodeAvmHost } from './node_avm_host.ts';

const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d; };
const url = arg('url', 'https://aztec-testnet.drpc.org');
const modulePath = arg('module', process.env.AVM_WASM_PATH);
const max = arg('max');
// SEE range.ts: reaching below the finalized tip is the CONTROL that demonstrates isolation, not a
// feature. Those rows come back `below-finalized` and the range still completes.
const below = arg('reach-below-finalized');
const json = argv.includes('--json');

if (!modulePath) {
  console.error('replay-window: --module <avm.wasm> (or AVM_WASM_PATH) is required');
  process.exit(2);
}

const client = createReplayNodeClient({ url });
const host = await createNodeAvmHost(modulePath);

const report = await replayReplayableWindow(client, host, client, encodeReplayInputs, {
  ...(max === undefined ? {} : { maxTransactions: Number(max) }),
  ...(below === undefined ? {} : { reachBelowFinalizedForControls: Number(below) }),
  onWindow: (w) => console.error(
    `replay-window: tip ${w.tip}, finalized ${w.finalized} — ${w.blocks} replayable block(s) `
    + `(${w.from}..${w.to})`),
  onOutcome: (o) => console.error(
    `replay-window: ${o.blockNumber}[${o.txIndexInBlock}] ${o.txHash.slice(0, 18)}… `
    + `${o.kind.toUpperCase()} (${o.elapsedMs} ms)`),
});

if (json) {
  console.log(JSON.stringify(report, null, 2));
} else {
  const w = report.window;
  console.log(`\nREPLAYABLE WINDOW  ${w.from}..${w.to}  (${w.blocks} blocks, tip ${w.tip}, finalized ${w.finalized})`);
  console.log(`blocks with transactions: ${report.blocksWithTransactions}`);
  console.log(`transactions enumerated:  ${report.transactions}`);
  console.log(`rows in the table:        ${report.outcomes.length}\n`);
  console.log('  BLOCK  IDX  OUTCOME             pub  rep  repro  instr   ms   TRANSACTION');
  for (const o of report.outcomes) {
    console.log(`  ${String(o.blockNumber).padStart(6)}  ${String(o.txIndexInBlock).padStart(3)}  `
      + `${o.kind.padEnd(18)}  ${String(o.publishedRevertCode ?? '-').padStart(3)}  `
      + `${String(o.replayedRevertCode ?? '-').padStart(3)}  `
      + `${String(o.reproduced ?? '-').padStart(5)}  `
      + `${String(o.instructionsExecuted ?? '-').padStart(5)}  `
      + `${String(o.elapsedMs).padStart(5)}   ${o.txHash.slice(0, 20)}…`);
    if (o.kind !== 'replayed') console.log(`         ${o.refusalKind ?? ''} ${o.detail.slice(0, 150)}`);
  }
  console.log('\nby outcome:', JSON.stringify(report.byKind));
  console.log(`rate: ${report.transactionsPerMinute.toFixed(1)} transactions/minute `
    + `(${report.elapsedMs} ms total)`);
  console.log(`where the time went: enumerate ${report.timing.enumerateMs} ms, `
    + `replay ${report.timing.replayMs} ms, slowest transaction ${report.timing.slowestTransactionMs} ms`);
}

// A RANGE THAT COMPLETED IS A SUCCESS EVEN WITH FAILED ROWS — that is what isolation MEANS. The
// exit status reports whether every transaction that COULD be replayed was, which is a different
// question and the one a caller wants.
const replayable = report.outcomes.filter((o) => o.kind === 'replayed');
const reproduced = replayable.filter((o) => o.reproduced === true);
process.exit(replayable.length > 0 && reproduced.length === replayable.length ? 0 : 1);
